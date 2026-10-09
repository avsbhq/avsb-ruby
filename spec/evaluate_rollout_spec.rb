# frozen_string_literal: true

require "spec_helper"

# Targeted delivery rollouts (N1-1, production QA 2026-10-01).
#
# A TARGETED_DELIVERY rule with trafficAllocation 0.3 used to serve 100
# percent of its audience in every SDK, because the evaluator only applied the
# allocation to ab_test rules. These specs lock the fix: the same gate, hash
# input and float threshold as an ab_test rule. They mirror
# packages/avsb-core/src/evaluate.rollout.test.ts, and the exact counts were
# computed by the TypeScript reference (@avsbhq/core 1.6.0) over the same keys.
RSpec.describe "Avsb::Core::Evaluator targeted delivery rollouts" do
  def rule(allocation, id: "rule_rollout", variation_id: "var_on", type: "targeted_delivery",
           audience_ids: [], with_variations: true)
    {
      "id" => id,
      "type" => type,
      "enabled" => true,
      "audienceIds" => audience_ids,
      "hashAttribute" => "user.key",
      "trafficAllocation" => allocation,
      "variations" => with_variations ? [{ "variationId" => variation_id, "percentage" => 1 }] : []
    }
  end

  def datafile(rules, audiences = [])
    {
      "version" => 2,
      "projectType" => "FEATURE_FLAG",
      "sdkKey" => "sdk_test_rolloutfixture00001",
      "environmentKey" => "test",
      "publishedAt" => "2026-10-01T00:00:00.000Z",
      "collectEndpoint" => "https://collect.test.invalid",
      "flags" => [
        {
          "id" => "flag_rollout",
          "key" => "rollout_feature",
          "type" => "boolean",
          "enabled" => true,
          "defaultVariationId" => "var_off",
          "variations" => [
            { "id" => "var_off", "key" => "off", "value" => false },
            { "id" => "var_on", "key" => "on", "value" => true },
            { "id" => "var_fallback", "key" => "fallback", "value" => true }
          ],
          "overrides" => [],
          "rules" => rules
        }
      ],
      "audiences" => audiences
    }
  end

  def evaluate(datafile, key, attributes: {}, reasons: nil, on_exposure: nil)
    Avsb::Core::Evaluator.evaluate_flag(
      "rollout_feature", false, { "kind" => "user", "key" => key }.merge(attributes), datafile,
      reasons: reasons, on_exposure: on_exposure
    )
  end

  def served_count(datafile, count = 10_000)
    (0...count).count { |i| evaluate(datafile, "user-#{i}")[:rule_id] == "rule_rollout" }
  end

  def allocation_bucket(key)
    Avsb::Core::Hash.murmurhash3("#{key}rollout_feature__rule_rollout") % 10_000
  end

  def key_for_allocation_bucket(bucket, prefix)
    200_000.times do |i|
      candidate = "#{prefix}-#{i}"
      return candidate if allocation_bucket(candidate) == bucket
    end
    raise "no key hashed to allocation bucket #{bucket}"
  end

  describe "rollout share" do
    it "serves a 30 percent rule to the reference share of 10,000 users" do
      # The TypeScript reference serves exactly 2,984 of these keys.
      expect(served_count(datafile([rule(0.3)]))).to eq(2984)
    end

    it "matches the reference counts at 5 and 50 percent" do
      expect(served_count(datafile([rule(0.05)]))).to eq(536)
      expect(served_count(datafile([rule(0.5)]))).to eq(4939)
    end

    it "serves a null allocation to everyone, exactly as before the fix" do
      expect(served_count(datafile([rule(nil)]), 2000)).to eq(2000)
    end

    it "serves a full allocation to everyone and a zero allocation to no one" do
      expect(served_count(datafile([rule(1)]), 2000)).to eq(2000)
      expect(served_count(datafile([rule(0)]), 2000)).to eq(0)
    end

    it "keeps everyone already in a rollout when it grows from 5 to 30 percent" do
      small = datafile([rule(0.05)])
      large = datafile([rule(0.3)])
      2000.times do |i|
        next unless evaluate(small, "user-#{i}")[:rule_id] == "rule_rollout"

        expect(evaluate(large, "user-#{i}")[:rule_id]).to eq("rule_rollout")
      end
    end
  end

  describe "rollout membership" do
    it "uses the ab_test allocation hash input, so both rule types agree per visitor" do
      as_targeted = datafile([rule(0.3)])
      as_ab_test = datafile([rule(0.3, type: "ab_test")])
      2000.times do |i|
        in_rollout = allocation_bucket("user-#{i}") < 3000
        expect(evaluate(as_targeted, "user-#{i}")[:rule_id] == "rule_rollout").to eq(in_rollout)
        expect(evaluate(as_ab_test, "user-#{i}")[:rule_id] == "rule_rollout").to eq(in_rollout)
      end
    end

    it "buckets the first users exactly as the reference does" do
      expect((0..4).map { |i| allocation_bucket("user-#{i}") }).to eq([5278, 8498, 4278, 4172, 1088])
    end

    it "compares against the raw float threshold: bucket 1234 is in a 0.12345 rollout" do
      df = datafile([rule(0.12345)])
      inside = key_for_allocation_bucket(1234, "td-in")
      outside = key_for_allocation_bucket(1235, "td-out")
      # The same keys the TypeScript search settles on.
      expect([inside, outside]).to eq(%w[td-in-3679 td-out-19194])

      expect(evaluate(df, inside)[:rule_id]).to eq("rule_rollout")

      reasons = []
      result = evaluate(df, outside, reasons: reasons)
      expect(result[:source]).to eq("default")
      expect(reasons).to eq([
        'rule "rule_rollout" excluded by traffic allocation (hash 1235 >= threshold 1234.5)',
        "no rules matched, returning default variation"
      ])
    end

    it "lets a visitor outside the rollout fall through to the next rule" do
      df = datafile([rule(0.3), rule(nil, id: "rule_everyone", variation_id: "var_fallback")])
      result = evaluate(df, key_for_allocation_bucket(9000, "td-next"))
      expect(result[:rule_id]).to eq("rule_everyone")
      expect(result[:variation_key]).to eq("fallback")
    end

    it "still skips on an audience miss before the rollout is consulted" do
      paid = {
        "id" => "aud_paid",
        "rules" => {
          "id" => "g_root",
          "logic" => "AND",
          "conditions" => [
            {
              "id" => "c_plan", "type" => "CUSTOM_ATTRIBUTE", "attribute" => "plan",
              "operator" => "equals", "value" => "paid", "contextKind" => "user"
            }
          ]
        }
      }
      df = datafile([rule(1, audience_ids: ["aud_paid"])], [paid])
      reasons = []
      result = evaluate(df, "free-user", attributes: { "plan" => "free" }, reasons: reasons)
      expect(result[:source]).to eq("default")
      expect(reasons.first).to eq('rule "rule_rollout" skipped (audience not matched)')
    end

    it "keeps a rule with no variations a silent skip, whatever its allocation" do
      reasons = []
      evaluate(datafile([rule(0, with_variations: false)]), "u1", reasons: reasons)
      expect(reasons).to eq(["no rules matched, returning default variation"])
    end

    it "fires no exposure for a targeted delivery decision, rollout or not" do
      exposures = []
      result = evaluate(
        datafile([rule(0.3)]), key_for_allocation_bucket(10, "td-expo"),
        on_exposure: ->(event) { exposures << event }
      )
      expect(result[:rule_type]).to eq("targeted_delivery")
      expect(exposures).to eq([])
    end
  end
end
