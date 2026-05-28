# frozen_string_literal: true

require "spec_helper"

RSpec.describe Avsb::DecisionLog do
  subject(:log) { described_class.new }

  let(:entry) do
    Avsb::DecisionLogEntry.new(
      flag_key:        "my-flag",
      value:           true,
      variation_key:   "on",
      source:          "rule",
      rule_id:         "rule_1",
      rule_type:       "targeted_delivery",
      reasons:         ["rule matched"],
      evaluated_at:    1_700_000_000_000,
      context_summary: [{ kind: "user", key: "alice" }],
    )
  end

  it "starts empty" do
    expect(log.entries).to be_empty
  end

  it "records an entry" do
    log.record(entry)
    expect(log.entries.length).to eq(1)
    expect(log.entries.first.flag_key).to eq("my-flag")
  end

  it "preserves insertion order" do
    e2 = entry.with(flag_key: "other-flag")
    log.record(entry)
    log.record(e2)
    expect(log.entries.map(&:flag_key)).to eq(%w[my-flag other-flag])
  end

  it "clears all entries" do
    log.record(entry)
    log.clear
    expect(log.entries).to be_empty
  end
end

RSpec.describe Avsb::DecisionLogEntry do
  let(:base_entry) do
    Avsb::DecisionLogEntry.new(
      flag_key:        "flag",
      value:           "alice@company.com",
      variation_key:   "on",
      source:          "rule",
      rule_id:         "r1",
      rule_type:       "targeted_delivery",
      reasons:         ["matched email=alice@company.com"],
      evaluated_at:    1_700_000_000_000,
    )
  end

  it "redacts private attribute values from reasons" do
    redacted = base_entry.redact(["alice@company.com"])
    expect(redacted.reasons.first).to include("[REDACTED]")
    expect(redacted.reasons.first).not_to include("alice@company.com")
  end

  it "returns self unchanged when no private attrs" do
    result = base_entry.redact([])
    expect(result.reasons).to eq(base_entry.reasons)
  end

  it "returns self unchanged when private_attrs is nil" do
    result = base_entry.redact(nil)
    expect(result).to equal(base_entry)
  end

  it "is immutable (Data.define)" do
    expect { base_entry.instance_variable_set(:@flag_key, "x") }.to raise_error(FrozenError)
  end
end
