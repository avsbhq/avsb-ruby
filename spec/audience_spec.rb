# frozen_string_literal: true

require "spec_helper"

RSpec.describe Avsb::Core::Audience do
  def ctx(kind: "user", key: "u1", **attrs)
    h = { "kind" => kind, "key" => key }
    attrs.each { |k, v| h[k.to_s] = v }
    h
  end

  def audience(logic: "AND", conditions:)
    { "id" => "aud_1", "rules" => { "id" => "g1", "logic" => logic, "conditions" => conditions } }
  end

  def condition(attribute:, operator:, value:, type: "CUSTOM_ATTRIBUTE", context_kind: nil)
    c = { "id" => "c1", "type" => type, "attribute" => attribute, "operator" => operator, "value" => value }
    c["contextKind"] = context_kind if context_kind
    c
  end

  # --- exists / not_exists ---

  it "matches exists when attribute is present" do
    aud = audience(conditions: [condition(attribute: "plan", operator: "exists", value: "")])
    expect(described_class.evaluate_audience(aud, ctx(plan: "pro"))).to be true
  end

  it "fails exists when attribute is absent" do
    aud = audience(conditions: [condition(attribute: "plan", operator: "exists", value: "")])
    expect(described_class.evaluate_audience(aud, ctx)).to be false
  end

  it "matches not_exists when attribute is absent" do
    aud = audience(conditions: [condition(attribute: "plan", operator: "not_exists", value: "")])
    expect(described_class.evaluate_audience(aud, ctx)).to be true
  end

  # --- equals / not_equals ---

  it "matches equals operator" do
    aud = audience(conditions: [condition(attribute: "plan", operator: "equals", value: "pro")])
    expect(described_class.evaluate_audience(aud, ctx(plan: "pro"))).to  be true
    expect(described_class.evaluate_audience(aud, ctx(plan: "free"))).to be false
  end

  it "matches not_equals operator" do
    aud = audience(conditions: [condition(attribute: "plan", operator: "not_equals", value: "free")])
    expect(described_class.evaluate_audience(aud, ctx(plan: "pro"))).to be true
  end

  # --- contains / not_contains ---

  it "matches contains (case-insensitive)" do
    aud = audience(conditions: [condition(attribute: "email", operator: "contains", value: "ACME")])
    expect(described_class.evaluate_audience(aud, ctx(email: "user@acme.com"))).to be true
  end

  it "matches not_contains" do
    aud = audience(conditions: [condition(attribute: "email", operator: "not_contains", value: "rival")])
    expect(described_class.evaluate_audience(aud, ctx(email: "user@acme.com"))).to be true
  end

  # --- starts_with / ends_with ---

  it "matches starts_with" do
    aud = audience(conditions: [condition(attribute: "key", operator: "starts_with", value: "user_")])
    expect(described_class.evaluate_audience(aud, ctx(key: "user_123"))).to be true
  end

  it "matches ends_with" do
    aud = audience(conditions: [condition(attribute: "email", operator: "ends_with", value: ".com")])
    expect(described_class.evaluate_audience(aud, ctx(email: "admin@company.com"))).to be true
  end

  # --- numeric operators ---

  it "matches greater_than" do
    aud = audience(conditions: [condition(attribute: "age", operator: "greater_than", value: "18")])
    expect(described_class.evaluate_audience(aud, ctx(age: 25))).to be true
    expect(described_class.evaluate_audience(aud, ctx(age: 18))).to be false
  end

  it "matches less_than" do
    aud = audience(conditions: [condition(attribute: "score", operator: "less_than", value: "100")])
    expect(described_class.evaluate_audience(aud, ctx(score: 50))).to be true
  end

  it "matches gte and lte" do
    aud_gte = audience(conditions: [condition(attribute: "score", operator: "gte", value: "10")])
    aud_lte = audience(conditions: [condition(attribute: "score", operator: "lte", value: "10")])
    expect(described_class.evaluate_audience(aud_gte, ctx(score: 10))).to be true
    expect(described_class.evaluate_audience(aud_lte, ctx(score: 10))).to be true
  end

  # --- in_list / not_in_list ---

  it "matches in_list" do
    aud = audience(conditions: [condition(attribute: "plan", operator: "in_list", value: %w[pro enterprise])])
    expect(described_class.evaluate_audience(aud, ctx(plan: "pro"))).to       be true
    expect(described_class.evaluate_audience(aud, ctx(plan: "free"))).to      be false
  end

  it "matches not_in_list" do
    aud = audience(conditions: [condition(attribute: "plan", operator: "not_in_list", value: %w[free trial])])
    expect(described_class.evaluate_audience(aud, ctx(plan: "pro"))).to be true
  end

  # --- regex ---

  it "matches regex operator" do
    aud = audience(conditions: [condition(attribute: "email", operator: "regex", value: "^admin@")])
    expect(described_class.evaluate_audience(aud, ctx(email: "admin@co.com"))).to be true
    expect(described_class.evaluate_audience(aud, ctx(email: "user@co.com"))).to  be false
  end

  it "returns false for an invalid regex without raising" do
    aud = audience(conditions: [condition(attribute: "email", operator: "regex", value: "[")])
    expect { described_class.evaluate_audience(aud, ctx(email: "x")) }.not_to raise_error
    expect(described_class.evaluate_audience(aud, ctx(email: "x"))).to be false
  end

  # --- AND / OR logic ---

  it "AND logic requires all conditions to match" do
    conds = [
      condition(attribute: "plan", operator: "equals", value: "pro"),
      condition(attribute: "country", operator: "equals", value: "US"),
    ]
    aud = audience(logic: "AND", conditions: conds)
    expect(described_class.evaluate_audience(aud, ctx(plan: "pro", country: "US"))).to  be true
    expect(described_class.evaluate_audience(aud, ctx(plan: "pro", country: "GB"))).to  be false
  end

  it "OR logic requires at least one condition to match" do
    conds = [
      condition(attribute: "plan", operator: "equals", value: "pro"),
      condition(attribute: "plan", operator: "equals", value: "enterprise"),
    ]
    aud = audience(logic: "OR", conditions: conds)
    expect(described_class.evaluate_audience(aud, ctx(plan: "enterprise"))).to be true
    expect(described_class.evaluate_audience(aud, ctx(plan: "free"))).to       be false
  end

  # --- Multi-context kinded condition ---

  it "evaluates a kinded condition against the correct sub-context" do
    multi_ctx = {
      "kind"         => "multi",
      "user"         => { "kind" => "user", "key" => "u1" },
      "organization" => { "kind" => "organization", "key" => "org_1", "tier" => "enterprise" },
    }
    aud = audience(conditions: [
      condition(attribute: "tier", operator: "equals", value: "enterprise", context_kind: "organization"),
    ])
    expect(described_class.evaluate_audience(aud, multi_ctx)).to be true
  end

  it "returns false when kinded context kind is absent in multi-context" do
    multi_ctx = { "kind" => "multi", "user" => { "kind" => "user", "key" => "u1" } }
    aud = audience(conditions: [
      condition(attribute: "tier", operator: "equals", value: "enterprise", context_kind: "organization"),
    ])
    expect(described_class.evaluate_audience(aud, multi_ctx)).to be false
  end

  # --- Unknown / browser-only condition types ---

  it "returns false for unknown condition type (DEVICE, BROWSER, etc. are server-unsupported)" do
    c = { "id" => "c_dev", "type" => "DEVICE", "attribute" => nil, "operator" => "equals", "value" => "mobile" }
    aud = audience(conditions: [c])
    expect(described_class.evaluate_audience(aud, ctx)).to be false
  end

  # --- Edge cases ---

  it "returns true for an audience with no conditions" do
    aud = { "id" => "aud_empty", "rules" => { "id" => "g1", "logic" => "AND", "conditions" => [] } }
    expect(described_class.evaluate_audience(aud, ctx)).to be true
  end

  it "returns true for a nil audience" do
    expect(described_class.evaluate_audience(nil, ctx)).to be true
  end
end
