# frozen_string_literal: true

require "spec_helper"

RSpec.describe Avsb::Sticky::InMemory do
  subject(:store) { described_class.new }

  let(:assignment) do
    { variation_id: "var_on", rule_id: "rule_1", rule_type: "targeted_delivery",
      assigned_at: 1_700_000_000_000 }
  end

  it "returns nil when no assignment exists" do
    expect(store.lookup("alice", "my-flag")).to be_nil
  end

  it "round-trips an assignment" do
    store.save("alice", "my-flag", assignment)
    result = store.lookup("alice", "my-flag")
    expect(result).to eq(assignment)
  end

  it "isolates assignments per flag key" do
    store.save("alice", "flag-a", assignment)
    expect(store.lookup("alice", "flag-b")).to be_nil
  end

  it "isolates assignments per user id" do
    store.save("alice", "my-flag", assignment)
    expect(store.lookup("bob", "my-flag")).to be_nil
  end

  it "overwrites an existing assignment" do
    store.save("alice", "my-flag", assignment)
    new_assignment = assignment.merge(variation_id: "var_off")
    store.save("alice", "my-flag", new_assignment)
    expect(store.lookup("alice", "my-flag")[:variation_id]).to eq("var_off")
  end

  it "tracks size correctly" do
    expect(store.size).to eq(0)
    store.save("alice", "flag-a", assignment)
    store.save("alice", "flag-b", assignment)
    expect(store.size).to eq(2)
  end

  it "clears all assignments" do
    store.save("alice", "my-flag", assignment)
    store.clear
    expect(store.lookup("alice", "my-flag")).to be_nil
  end
end
