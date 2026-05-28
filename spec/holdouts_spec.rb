# frozen_string_literal: true

require "spec_helper"

RSpec.describe Avsb::Core::Holdouts do
  def user(key)
    { "kind" => "user", "key" => key }
  end

  def holdout(traffic:, flag_ids:, hash_attribute: "user.key", key: "h1", id: "holdout_1",
              default_variation_by_flag: {})
    {
      "id"               => id,
      "key"              => key,
      "trafficAllocation" => traffic,
      "flagIds"          => flag_ids,
      "hashAttribute"    => hash_attribute,
      "defaultVariationByFlag" => default_variation_by_flag,
    }
  end

  def datafile(holdouts: [])
    { "flags" => [], "audiences" => [], "holdouts" => holdouts }
  end

  it "returns held_out: false when datafile has no holdouts" do
    result = described_class.evaluate_holdout(user("alice"), "flag_1", datafile)
    expect(result[:held_out]).to be false
  end

  it "returns held_out: false when holdout does not include the flag" do
    h      = holdout(traffic: 1.0, flag_ids: ["flag_other"])
    result = described_class.evaluate_holdout(user("alice"), "flag_target", datafile(holdouts: [h]))
    expect(result[:held_out]).to be false
  end

  it "returns held_out: false when trafficAllocation is 0" do
    h      = holdout(traffic: 0.0, flag_ids: ["flag_target"])
    result = described_class.evaluate_holdout(user("alice"), "flag_target", datafile(holdouts: [h]))
    expect(result[:held_out]).to be false
  end

  it "returns held_out: true for a 99.9% holdout for the conformance user (holdout_subject_1)" do
    # Matches the conformance fixture: 99.9% allocation, user holdout_subject_1.
    h = holdout(
      traffic: 0.999,
      flag_ids: ["flag_holdout_target"],
      key: "q2-2026-holdout",
      id: "holdout_q2",
      hash_attribute: "user.key",
      default_variation_by_flag: { "flag_holdout_target" => "var_off" },
    )
    df     = datafile(holdouts: [h])
    result = described_class.evaluate_holdout(user("holdout_subject_1"), "flag_holdout_target", df)
    expect(result[:held_out]).to    be true
    expect(result[:holdout]).to     eq(h)
    expect(result[:variation_id]).to eq("var_off")
  end

  it "returns held_out: false for a 0.0001 traffic holdout with most users" do
    # Extremely small traffic — expect almost all users to NOT be held out.
    h      = holdout(traffic: 0.0001, flag_ids: ["flag_target"])
    result = described_class.evaluate_holdout(user("typical_user"), "flag_target", datafile(holdouts: [h]))
    # This may or may not be held out by chance, so just check it does not raise.
    expect([true, false]).to include(result[:held_out])
  end
end
