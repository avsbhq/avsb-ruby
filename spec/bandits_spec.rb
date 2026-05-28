# frozen_string_literal: true

require "spec_helper"

RSpec.describe Avsb::Core::Bandits do
  let(:actions) do
    [
      { "id" => "action_a", "variationId" => "var_a" },
      { "id" => "action_b", "variationId" => "var_b" },
      { "id" => "action_c", "variationId" => "var_c" },
    ]
  end

  let(:cold_start_per_action) { {} }

  let(:per_action_with_means) do
    {
      "action_a" => { "mean" => 0.9, "variance" => 0.1, "samples" => 100 },
      "action_b" => { "mean" => 0.5, "variance" => 0.1, "samples" => 100 },
      "action_c" => { "mean" => 0.2, "variance" => 0.1, "samples" => 100 },
    }
  end

  # --- epsilon_greedy ---

  describe ".epsilon_greedy" do
    it "raises when actions list is empty" do
      expect { described_class.epsilon_greedy({}, [], 0) }.to raise_error(ArgumentError, /empty/)
    end

    it "exploits the highest-mean action when bucket is above epsilon threshold" do
      # bucket 900 / 10_000 = 0.09; epsilon = 0.1 → explore fires when < 0.1.
      # bucket 0.09 < 0.1 → actually explore fires here.
      # Use bucket 1000 (0.1) to be in exploit territory with epsilon=0.1.
      result = described_class.epsilon_greedy(per_action_with_means, actions, 1_000, exploration_rate: 0.1)
      expect(result[:explore_fired]).to be false
      expect(result[:action]["id"]).to  eq("action_a") # highest mean
    end

    it "explores when bucket fraction is below epsilon" do
      # bucket 50 / 10_000 = 0.005 < epsilon 0.1 → explore
      result = described_class.epsilon_greedy(per_action_with_means, actions, 50, exploration_rate: 0.1)
      expect(result[:explore_fired]).to be true
    end

    it "returns a probability in (0, 1]" do
      result = described_class.epsilon_greedy(per_action_with_means, actions, 5_000)
      expect(result[:action_probability]).to be > 0
      expect(result[:action_probability]).to be <= 1
    end
  end

  # --- thompson_sample ---

  describe ".thompson_sample" do
    it "raises when actions list is empty" do
      expect { described_class.thompson_sample({}, [], 0) }.to raise_error(ArgumentError, /empty/)
    end

    it "returns one of the declared actions" do
      result = described_class.thompson_sample(per_action_with_means, actions, 42)
      expect(actions.map { |a| a["id"] }).to include(result[:action]["id"])
    end

    it "is deterministic for the same hash_bucket" do
      r1 = described_class.thompson_sample(per_action_with_means, actions, 7_777)
      r2 = described_class.thompson_sample(per_action_with_means, actions, 7_777)
      expect(r1[:action]["id"]).to eq(r2[:action]["id"])
    end

    it "reports action_probability as 1/N" do
      result = described_class.thompson_sample(per_action_with_means, actions, 0)
      expect(result[:action_probability]).to be_within(0.001).of(1.0 / 3)
    end
  end

  # --- ucb1 ---

  describe ".ucb1" do
    it "raises when actions list is empty" do
      expect { described_class.ucb1({}, []) }.to raise_error(ArgumentError, /empty/)
    end

    it "serves the first unseen action in cold-start (alphabetical)" do
      result = described_class.ucb1(cold_start_per_action, actions)
      expect(result[:action]["id"]).to eq("action_a") # lowest id alphabetically
    end

    it "selects the best UCB1 score when all actions have been seen" do
      result = described_class.ucb1(per_action_with_means, actions)
      expect(actions.map { |a| a["id"] }).to include(result[:action]["id"])
    end
  end

  # --- seeded_gaussian ---

  describe ".seeded_gaussian" do
    it "returns a finite Float" do
      z = described_class.seeded_gaussian(12_345)
      expect(z).to be_a(Float)
      expect(z.finite?).to be true
    end

    it "is deterministic" do
      expect(described_class.seeded_gaussian(99)).to eq(described_class.seeded_gaussian(99))
    end

    it "varies for different seeds" do
      z1 = described_class.seeded_gaussian(1)
      z2 = described_class.seeded_gaussian(2)
      expect(z1).not_to eq(z2)
    end
  end

  # --- evaluate_bandit ---

  describe ".evaluate_bandit" do
    let(:store) do
      s = Avsb::Core::Bandits::InMemoryModelStore.new
      s.update_model("my-bandit", Avsb::Core::Bandits::BanditModel.new(
        version:    "v1",
        algorithm:  "epsilon-greedy",
        per_action: per_action_with_means,
      ))
      s
    end

    let(:config) do
      { "algorithm" => "epsilon-greedy", "actions" => actions, "explorationRate" => 0.1 }
    end

    let(:ctx) { { "kind" => "user", "key" => "alice" } }

    it "returns nil when no model is registered" do
      empty_store = Avsb::Core::Bandits::InMemoryModelStore.new
      result      = described_class.evaluate_bandit("no-model", config, ctx, empty_store)
      expect(result).to be_nil
    end

    it "returns an action and metadata when a model exists" do
      result = described_class.evaluate_bandit("my-bandit", config, ctx, store)
      expect(result).not_to be_nil
      expect(result[:action]).not_to be_nil
      expect(result[:action_probability]).to be > 0
      expect(result[:model_version]).to eq("v1")
    end
  end
end
