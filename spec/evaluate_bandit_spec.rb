# frozen_string_literal: true

require "spec_helper"

# Bandit dispatch, unknown rule types, and the threshold math that used to
# diverge between languages. These mirror the bandit and boundary families of
# the conformance corpus; conformance_spec.rb runs the recorded cases, and
# these assert the same behaviour from hand-built datafiles so a failure says
# which rule is wrong rather than which fixture.
RSpec.describe Avsb::Core::Evaluator do
  def variations
    [
      { "id" => "var_control", "key" => "control", "value" => "control-copy" },
      { "id" => "var_bold",    "key" => "bold",    "value" => "bold-copy" },
      { "id" => "var_plain",   "key" => "plain",   "value" => "plain-copy" },
    ]
  end

  def flag_with(rules:, key: "bandit-feature")
    {
      "id" => "flag_1", "key" => key, "type" => "string", "enabled" => true,
      "defaultVariationId" => "var_control", "variations" => variations,
      "overrides" => [], "rules" => rules
    }
  end

  def bandit_rule(id:, algorithm: "ucb1", actions: nil, bandit_id: nil, enabled: true)
    rule = {
      "id" => id, "type" => "bandit", "enabled" => enabled, "audienceIds" => [],
      "hashAttribute" => "user.key", "trafficAllocation" => nil, "variations" => []
    }
    if bandit_id
      rule["banditId"] = bandit_id
    else
      rule["bandit"] = {
        "algorithm" => algorithm,
        "rewardMetric" => "checkout_completed",
        "actions" => actions || [
          { "id" => "action_a_bold", "variationId" => "var_bold" },
          { "id" => "action_b_plain", "variationId" => "var_plain" },
        ],
      }
    end
    rule
  end

  def datafile(flags:, bandits: nil)
    df = {
      "version" => 2, "projectType" => "FEATURE_FLAG",
      "sdkKey" => "sdk_production_banditfixture01", "environmentKey" => "production",
      "publishedAt" => "2026-05-29T00:00:00.000Z",
      "collectEndpoint" => "https://ingest.avsb.cloud",
      "flags" => flags, "audiences" => []
    }
    df["bandits"] = bandits if bandits
    df
  end

  let(:ctx) { { "kind" => "user", "key" => "user_bandit" } }

  describe "bandit dispatch" do
    it "serves the cold-start action with source=bandit when no model store is supplied" do
      df = datafile(flags: [flag_with(rules: [bandit_rule(id: "rule_b")])])
      reasons = []
      result  = described_class.evaluate_flag("bandit-feature", "caller-default", ctx, df,
                                              reasons: reasons)

      expect(result[:source]).to eq("bandit")
      expect(result[:rule_type]).to eq("bandit")
      expect(result[:rule_id]).to eq("rule_b")
      # UCB1 samples every unseen action once, lowest id first.
      expect(result[:variation_key]).to eq("bold")
      expect(result[:value]).to eq("bold-copy")
      expect(reasons).to eq([
        'rule "rule_b" matched (bandit "rule_b"), served action "action_a_bold" ' \
        'into variation "bold"',
      ])
    end

    it "resolves a shared banditId and attributes the decision to the shared key" do
      rule = bandit_rule(id: "rule_shared", bandit_id: "bandit_checkout")
      bandits = [{
        "id" => "bandit_checkout", "key" => "checkout-copy-bandit",
        "config" => {
          "algorithm" => "ucb1", "rewardMetric" => "checkout_completed",
          "actions" => [
            { "id" => "action_c_plain", "variationId" => "var_plain" },
            { "id" => "action_a_bold", "variationId" => "var_bold" },
          ],
        },
      }]
      df = datafile(flags: [flag_with(rules: [rule])], bandits: bandits)
      reasons = []
      result = described_class.evaluate_flag("bandit-feature", "caller-default", ctx, df,
                                            reasons: reasons)

      expect(result[:source]).to eq("bandit")
      expect(reasons.first).to include('matched (bandit "checkout-copy-bandit")')
    end

    it "records an exposure with the bandit key and action id" do
      df = datafile(flags: [flag_with(rules: [bandit_rule(id: "rule_b")])])
      captured = []
      described_class.evaluate_flag("bandit-feature", "caller-default", ctx, df,
                                    on_exposure: ->(e) { captured << e })

      expect(captured.length).to eq(1)
      event = captured.first
      expect(event["eventName"]).to eq("flag_exposure")
      expect(event["experimentId"]).to eq("rule_b")
      expect(event["variationId"]).to eq("var_bold")
      expect(event["properties"]).to include(
        "flagKey" => "bandit-feature", "banditKey" => "rule_b", "actionId" => "action_a_bold"
      )
    end

    it "prefers a supplied model store over the cold-start fallback" do
      store = Avsb::Core::Bandits::InMemoryModelStore.new
      store.update_model("rule_b", Avsb::Core::Bandits::BanditModel.new(
                                     version: "v1", algorithm: "ucb1",
                                     per_action: {
                                       "action_a_bold" => { "mean" => 0.1, "variance" => 1.0,
                                                            "samples" => 10 },
                                       "action_b_plain" => { "mean" => 0.9, "variance" => 1.0,
                                                             "samples" => 10 },
                                     }
                                   ))
      df = datafile(flags: [flag_with(rules: [bandit_rule(id: "rule_b")])])
      result = described_class.evaluate_flag("bandit-feature", "caller-default", ctx, df,
                                            bandit_model_store: store)

      # With observations on both arms the higher mean wins, so the cold-start
      # tie-break is not what produced this.
      expect(result[:variation_key]).to eq("plain")
    end
  end

  describe "bandit rules that cannot dispatch" do
    it "names a bandit rule carrying no config" do
      rule = { "id" => "rule_none", "type" => "bandit", "enabled" => true,
               "audienceIds" => [], "hashAttribute" => "user.key",
               "trafficAllocation" => nil, "variations" => [] }
      df = datafile(flags: [flag_with(rules: [rule])])
      reasons = []
      result = described_class.evaluate_flag("bandit-feature", "caller-default", ctx, df,
                                            reasons: reasons)

      expect(result[:source]).to eq("default")
      expect(reasons).to eq([
        'rule "rule_none" skipped (bandit rule carries no bandit config)',
        "no rules matched, returning default variation",
      ])
    end

    it "names an unresolvable banditId" do
      df = datafile(flags: [flag_with(rules: [bandit_rule(id: "rule_ghost",
                                                          bandit_id: "bandit_missing")])])
      reasons = []
      described_class.evaluate_flag("bandit-feature", "caller-default", ctx, df,
                                    reasons: reasons)

      expect(reasons.first).to eq(
        'rule "rule_ghost" skipped (banditId "bandit_missing" is not in datafile.bandits)'
      )
    end

    it "names a bandit declaring no actions" do
      df = datafile(flags: [flag_with(rules: [bandit_rule(id: "rule_empty", actions: [])])])
      reasons = []
      described_class.evaluate_flag("bandit-feature", "caller-default", ctx, df,
                                    reasons: reasons)

      expect(reasons.first).to eq(
        'rule "rule_empty" skipped (bandit "rule_empty" declares no actions)'
      )
    end

    it "names an action pointing at a variation the flag does not carry" do
      actions = [{ "id" => "action_ghost", "variationId" => "var_deleted" }]
      df = datafile(flags: [flag_with(rules: [bandit_rule(id: "rule_gv", actions: actions)])])
      reasons = []
      described_class.evaluate_flag("bandit-feature", "caller-default", ctx, df,
                                    reasons: reasons)

      expect(reasons.first).to eq(
        'rule "rule_gv" skipped (bandit "rule_gv" action "action_ghost" targets ' \
        'unknown variation "var_deleted")'
      )
    end

    it "skips a disabled bandit rule before it reaches the engine" do
      df = datafile(flags: [flag_with(rules: [bandit_rule(id: "rule_off", enabled: false)])])
      reasons = []
      described_class.evaluate_flag("bandit-feature", "caller-default", ctx, df,
                                    reasons: reasons)

      expect(reasons.first).to eq('rule "rule_off" skipped (disabled)')
    end
  end

  describe "unknown rule types" do
    it "names the type and lets a later rule serve" do
      future = { "id" => "rule_future", "type" => "multi_armed_rollout", "enabled" => true,
                 "audienceIds" => [], "hashAttribute" => "user.key",
                 "trafficAllocation" => nil,
                 "variations" => [{ "variationId" => "var_bold", "percentage" => 1 }] }
      known = { "id" => "rule_known", "type" => "targeted_delivery", "enabled" => true,
                "audienceIds" => [], "hashAttribute" => "user.key",
                "trafficAllocation" => nil,
                "variations" => [{ "variationId" => "var_plain", "percentage" => 1 }] }
      df = datafile(flags: [flag_with(rules: [future, known])])
      reasons = []
      result = described_class.evaluate_flag("bandit-feature", "caller-default", ctx, df,
                                            reasons: reasons)

      expect(result[:rule_id]).to eq("rule_known")
      expect(reasons.first).to eq(
        'rule "rule_future" skipped (unsupported rule type "multi_armed_rollout")'
      )
    end
  end

  describe "threshold and cumulative math" do
    let(:flag_key) { "alloc-feature" }
    let(:rule_id)  { "rule_alloc" }

    def ab_flag(traffic:, percentages:)
      rule = {
        "id" => rule_id, "type" => "ab_test", "enabled" => true, "audienceIds" => [],
        "hashAttribute" => "user.key", "trafficAllocation" => traffic,
        "variations" => percentages,
      }
      flag_with(rules: [rule], key: flag_key)
    end

    # The two buckets the evaluator will compute for this context, derived the
    # same way it does. Deriving them keeps the test independent of any one
    # recorded hash while still being exact.
    let(:user_key) { ctx["key"] }
    let(:alloc_bucket) do
      Avsb::Core::Hash.murmurhash3("#{user_key}#{flag_key}__#{rule_id}") % 10_000
    end
    let(:assignment_bucket) { Avsb::Core::Hash.murmurhash3("#{user_key}#{flag_key}") % 10_000 }

    it "includes the bucket that sits half a step below a fractional threshold" do
      # This is the case that catches truncated threshold math. The threshold
      # lands on bucket + 0.5, so a float comparison keeps the context inside
      # the rollout while flooring the threshold to bucket excludes it.
      traffic = (alloc_bucket + 0.5) / 10_000
      df = datafile(flags: [ab_flag(traffic: traffic, percentages: [
                                      { "variationId" => "var_bold", "percentage" => 1 },
                                    ])])
      result = described_class.evaluate_flag(flag_key, "caller-default", ctx, df)

      expect(result[:source]).to eq("rule")
      expect(result[:variation_key]).to eq("bold")
    end

    it "excludes the bucket that sits half a step above the same threshold" do
      # Proves the case above is not vacuous: the rule really can be skipped.
      traffic = (alloc_bucket - 0.5) / 10_000
      df = datafile(flags: [ab_flag(traffic: traffic, percentages: [
                                      { "variationId" => "var_bold", "percentage" => 1 },
                                    ])])
      reasons = []
      result = described_class.evaluate_flag(flag_key, "caller-default", ctx, df,
                                            reasons: reasons)

      expect(result[:source]).to eq("default")
      expect(reasons.first).to include("excluded by traffic allocation (hash #{alloc_bucket} >=")
    end

    it "prints an integral threshold without a decimal point" do
      # 0 percent excludes every bucket, so this is deterministic, and the
      # threshold must print as "0" rather than Ruby's "0.0". Every reason
      # string in the corpus is compared exactly.
      df = datafile(flags: [ab_flag(traffic: 0.0,
                                    percentages: [{ "variationId" => "var_bold",
                                                    "percentage" => 1 }])])
      reasons = []
      described_class.evaluate_flag(flag_key, "caller-default", ctx, df, reasons: reasons)

      expect(reasons.first).to end_with("threshold 0)")
    end

    it "keeps a cumulative variation boundary in floating point" do
      # The first variation's boundary lands on the assignment bucket plus a
      # half step, so the bucket belongs to it under float math and to the
      # next variation under a truncated one.
      first = (assignment_bucket + 0.5) / 10_000
      df = datafile(flags: [ab_flag(traffic: 1, percentages: [
                                      { "variationId" => "var_bold", "percentage" => first },
                                      { "variationId" => "var_plain", "percentage" => 1 - first },
                                    ])])
      reasons = []
      result = described_class.evaluate_flag(flag_key, "caller-default", ctx, df,
                                            reasons: reasons)

      expect(result[:variation_key]).to eq("bold")
      # The printed boundary carries its fraction rather than being rounded.
      expect(reasons.first).to match(%r{\(hash #{assignment_bucket}/\d+\.\d+\)\z})
    end
  end
end
