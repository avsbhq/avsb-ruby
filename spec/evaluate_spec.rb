# frozen_string_literal: true

require "spec_helper"

RSpec.describe Avsb::Core::Evaluator do
  # Minimal datafile builder helpers.

  def base_variation(id:, key:, value:)
    { "id" => id, "key" => key, "value" => value }
  end

  def base_flag(key:, enabled: true, default_variation_id: "var_off",
                variations: nil, overrides: [], rules: [])
    variations ||= [
      base_variation(id: "var_off", key: "off", value: false),
      base_variation(id: "var_on",  key: "on",  value: true),
    ]
    {
      "id"                 => "flag_#{key}",
      "key"                => key,
      "type"               => "boolean",
      "enabled"            => enabled,
      "defaultVariationId" => default_variation_id,
      "variations"         => variations,
      "overrides"          => overrides,
      "rules"              => rules,
    }
  end

  def datafile(flags: [], audiences: [], holdouts: [])
    {
      "version"           => 2,
      "projectType"       => "FEATURE_FLAG",
      "sdkKey"            => "test-key",
      "environmentKey"    => "production",
      "publishedAt"       => "2026-01-01T00:00:00.000Z",
      "collectEndpoint"   => "https://collect.avsb.cloud/v1/events",
      "flags"             => flags,
      "audiences"         => audiences,
      "holdouts"          => holdouts,
    }
  end

  def user(key, **attrs)
    h = { "kind" => "user", "key" => key }
    attrs.each { |k, v| h[k.to_s] = v }
    h
  end

  let(:ctx_alice) { user("alice") }

  # --- not_found ---

  it "returns not_found when the flag is missing from the datafile" do
    result = described_class.evaluate_flag("missing-flag", false, ctx_alice, datafile)
    expect(result[:source]).to        eq("not_found")
    expect(result[:value]).to         eq(false)
    expect(result[:variation_key]).to  be_nil
    expect(result[:rule_id]).to        be_nil
    expect(result[:reasons]).to        include(match(/not found in datafile/))
  end

  # --- disabled ---

  it "returns disabled source with default variation value when flag is disabled" do
    flag   = base_flag(key: "feature", enabled: false)
    result = described_class.evaluate_flag("feature", true, ctx_alice, datafile(flags: [flag]))
    expect(result[:source]).to       eq("disabled")
    expect(result[:value]).to        eq(false) # default variation value
    expect(result[:variation_key]).to eq("off")
  end

  # --- override ---

  it "returns override when user matches an explicit override" do
    flag   = base_flag(key: "feature", overrides: [{ "userId" => "alice", "variationId" => "var_on" }])
    result = described_class.evaluate_flag("feature", false, ctx_alice, datafile(flags: [flag]))
    expect(result[:source]).to        eq("datafileOverride")
    expect(result[:value]).to         eq(true)
    expect(result[:variation_key]).to  eq("on")
    expect(result[:reasons]).to        include(match(/override/))
  end

  it "does not apply override when user key differs" do
    flag   = base_flag(key: "feature", overrides: [{ "userId" => "bob", "variationId" => "var_on" }])
    result = described_class.evaluate_flag("feature", false, ctx_alice, datafile(flags: [flag]))
    expect(result[:source]).not_to eq("override")
  end

  # --- targeted_delivery ---

  it "returns rule/targeted_delivery when audience matches" do
    flag = base_flag(
      key: "feature",
      rules: [{
        "id"              => "rule_paid",
        "type"            => "targeted_delivery",
        "enabled"         => true,
        "audienceIds"     => ["aud_paid"],
        "hashAttribute"   => "user.key",
        "trafficAllocation" => nil,
        "variations"      => [{ "variationId" => "var_on", "percentage" => 1 }],
      }],
    )
    audience = {
      "id"    => "aud_paid",
      "rules" => { "id" => "g1", "logic" => "AND", "conditions" => [{
        "id" => "c1", "type" => "CUSTOM_ATTRIBUTE",
        "attribute" => "plan", "operator" => "equals", "value" => "pro",
      }] },
    }
    result = described_class.evaluate_flag("feature", false, user("alice", plan: "pro"),
                                            datafile(flags: [flag], audiences: [audience]))
    expect(result[:source]).to    eq("rule")
    expect(result[:rule_type]).to eq("targeted_delivery")
    expect(result[:value]).to     eq(true)
  end

  it "falls through to default when targeted_delivery audience does not match" do
    flag = base_flag(
      key: "feature",
      rules: [{
        "id"              => "rule_paid",
        "type"            => "targeted_delivery",
        "enabled"         => true,
        "audienceIds"     => ["aud_paid"],
        "hashAttribute"   => "user.key",
        "trafficAllocation" => nil,
        "variations"      => [{ "variationId" => "var_on", "percentage" => 1 }],
      }],
    )
    audience = {
      "id"    => "aud_paid",
      "rules" => { "id" => "g1", "logic" => "AND", "conditions" => [{
        "id" => "c1", "type" => "CUSTOM_ATTRIBUTE",
        "attribute" => "plan", "operator" => "equals", "value" => "pro",
      }] },
    }
    result = described_class.evaluate_flag("feature", false, user("alice", plan: "free"),
                                            datafile(flags: [flag], audiences: [audience]))
    expect(result[:source]).to eq("default")
  end

  # --- ab_test ---

  it "returns deterministic ab_test bucket for a known key" do
    flag = base_flag(
      key: "checkout-v2-experiment",
      variations: [
        { "id" => "var_control",   "key" => "control",   "value" => "old" },
        { "id" => "var_treatment", "key" => "treatment", "value" => "new" },
      ],
      default_variation_id: "var_control",
      rules: [{
        "id"                => "rule_ab_split",
        "type"              => "ab_test",
        "enabled"           => true,
        "audienceIds"       => [],
        "hashAttribute"     => "user.key",
        "trafficAllocation" => 1,
        "variations"        => [
          { "variationId" => "var_control",   "percentage" => 0.5 },
          { "variationId" => "var_treatment", "percentage" => 0.5 },
        ],
      }],
    )
    result = described_class.evaluate_flag("checkout-v2-experiment", "fallback",
                                            user("alice"), datafile(flags: [flag]))
    expect(result[:source]).to    eq("rule")
    expect(result[:rule_type]).to eq("ab_test")
    # alice hashes to control per conformance fixture
    expect(result[:variation_key]).to eq("control")
    expect(result[:value]).to          eq("old")
  end

  # --- holdout ---

  it "returns holdout source when user is held out" do
    flag = base_flag(
      key: "feature-with-holdout",
      rules: [{
        "id"                => "rule_full",
        "type"              => "targeted_delivery",
        "enabled"           => true,
        "audienceIds"       => [],
        "hashAttribute"     => "user.key",
        "trafficAllocation" => nil,
        "variations"        => [{ "variationId" => "var_on", "percentage" => 1 }],
      }],
    )
    holdout = {
      "id"               => "holdout_q2",
      "key"              => "q2-2026-holdout",
      "trafficAllocation" => 0.999,
      "flagIds"          => ["flag_feature-with-holdout"],
      "hashAttribute"    => "user.key",
      "defaultVariationByFlag" => { "flag_feature-with-holdout" => "var_off" },
    }
    result = described_class.evaluate_flag("feature-with-holdout", false,
                                            user("holdout_subject_1"),
                                            datafile(flags: [flag], holdouts: [holdout]))
    expect(result[:source]).to    eq("holdout")
    expect(result[:rule_type]).to eq("holdout")
  end

  # --- default ---

  it "returns default source when no rules match" do
    flag   = base_flag(key: "feature")
    result = described_class.evaluate_flag("feature", false, ctx_alice, datafile(flags: [flag]))
    expect(result[:source]).to        eq("default")
    expect(result[:value]).to         eq(false)
    expect(result[:variation_key]).to  eq("off")
    expect(result[:reasons]).to        include(match(/no rules matched/))
  end

  # --- reasons accumulation ---

  it "accumulates reasons into the provided array" do
    flag    = base_flag(key: "feature")
    reasons = []
    described_class.evaluate_flag("feature", false, ctx_alice, datafile(flags: [flag]), reasons: reasons)
    expect(reasons).not_to be_empty
  end

  # --- multi-context bucketing ---

  it "resolves dotted hash_attribute against multi-context" do
    flag = base_flag(
      key: "org-feature",
      rules: [{
        "id"                => "rule_org",
        "type"              => "targeted_delivery",
        "enabled"           => true,
        "audienceIds"       => [],
        "hashAttribute"     => "organization.key",
        "trafficAllocation" => nil,
        "variations"        => [{ "variationId" => "var_on", "percentage" => 1 }],
      }],
    )
    multi_ctx = {
      "kind"         => "multi",
      "user"         => { "kind" => "user", "key" => "u1" },
      "organization" => { "kind" => "organization", "key" => "org_1" },
    }
    result = described_class.evaluate_flag("org-feature", false, multi_ctx, datafile(flags: [flag]))
    expect(result[:source]).to eq("rule")
  end
end
