# frozen_string_literal: true

require_relative "hash"

module Avsb
  module Core
    # Bandit evaluation engine — epsilon-greedy, Thompson sampling, UCB1.
    #
    # Design invariants (preserved from the TypeScript source):
    #   - Algorithms are pure functions: no rand() — seeded from murmurhash3.
    #   - Tie-breaking is alphabetical on action id for determinism.
    module Bandits
      MAX_BUCKET  = 10_000
      HASH_RANGE  = 0x100000000 # 2^32

      # Per-action statistics struct.
      PerActionStats = Data.define(:mean, :variance, :samples)

      # Bandit model struct.
      BanditModel = Data.define(:version, :algorithm, :per_action, :contextual_models) do
        def initialize(version:, algorithm:, per_action:, contextual_models: nil)
          super
        end
      end

      # In-memory model store.
      class InMemoryModelStore
        def initialize(initial = {})
          @models = {}
          initial.each { |k, v| @models[k] = v }
        end

        def get_model(bandit_key)
          @models[bandit_key]
        end

        def update_model(bandit_key, model)
          @models[bandit_key] = model
        end
      end

      # --- Seeded pseudo-randomness ---

      def self.seeded_gaussian(seed)
        u1 = uniform_from_seed(seed, 1)
        u2 = uniform_from_seed(seed, 2)
        Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math::PI * u2)
      end

      def self.uniform_from_seed(seed, salt)
        hashed = Avsb::Core::Hash.murmurhash3("#{seed}:#{salt}")
        (hashed + 1).to_f / (HASH_RANGE + 1).to_f
      end
      private_class_method :uniform_from_seed

      # --- Helpers ---

      def self.sorted_actions(actions)
        actions.sort_by { |a| a["id"] || a[:id] }
      end

      def self.stats_for(per_action, action_id)
        s = per_action[action_id]
        return s if s

        { "mean" => 0.0, "variance" => 1.0, "samples" => 0 }
      end

      # --- Algorithm: epsilon-greedy ---

      def self.epsilon_greedy(model_per_action, actions, hash_bucket, exploration_rate: nil)
        raise ArgumentError, "epsilon_greedy: actions list is empty" if actions.empty?

        sorted  = sorted_actions(actions)
        epsilon = exploration_rate || 0.1
        n       = sorted.length
        explore_fired = (hash_bucket.to_f / MAX_BUCKET) < epsilon

        if explore_fired
          idx    = hash_bucket % n
          action = sorted[idx]
          return { action: action, action_probability: epsilon / n, explore_fired: true }
        end

        # Exploit branch — highest mean, alphabetical tie-break.
        best_id    = nil
        best_mean  = -Float::INFINITY
        best_count = 0

        sorted.each do |action|
          s = stats_for(model_per_action, action["id"] || action[:id])
          m = (s["mean"] || s[:mean]).to_f
          if m > best_mean
            best_mean  = m
            best_id    = action["id"] || action[:id]
            best_count = 1
          elsif m == best_mean
            best_count += 1
          end
        end

        action       = sorted.find { |a| (a["id"] || a[:id]) == best_id }
        exploit_mass = (1 - epsilon) / best_count
        { action: action, action_probability: exploit_mass + (epsilon / n), explore_fired: false }
      end

      # --- Algorithm: Thompson sampling ---

      def self.thompson_sample(model_per_action, actions, hash_bucket)
        raise ArgumentError, "thompson_sample: actions list is empty" if actions.empty?

        sorted       = sorted_actions(actions)
        best_id      = (sorted[0]["id"] || sorted[0][:id])
        best_sample  = -Float::INFINITY

        sorted.each do |action|
          aid   = action["id"] || action[:id]
          s     = stats_for(model_per_action, aid)
          seed  = Avsb::Core::Hash.murmurhash3("#{hash_bucket}:#{aid}")
          z     = seeded_gaussian(seed)
          variance = (s["variance"] || s[:variance]).to_f
          samples  = [(s["samples"] || s[:samples]).to_i, 1].max
          mean     = (s["mean"] || s[:mean]).to_f
          stddev   = Math.sqrt(variance / samples)
          sample   = mean + z * stddev
          if sample > best_sample
            best_sample = sample
            best_id     = aid
          end
        end

        action = sorted.find { |a| (a["id"] || a[:id]) == best_id }
        { action: action, action_probability: 1.0 / sorted.length }
      end

      # --- Algorithm: UCB1 ---

      def self.ucb1(model_per_action, actions)
        raise ArgumentError, "ucb1: actions list is empty" if actions.empty?

        sorted = sorted_actions(actions)

        # Cold-start: pick first unseen action.
        sorted.each do |action|
          s = stats_for(model_per_action, action["id"] || action[:id])
          return { action: action, action_probability: 1.0 } if (s["samples"] || s[:samples]).to_i == 0
        end

        total_samples = sorted.sum { |a| stats_for(model_per_action, a["id"] || a[:id])["samples"].to_i }
        ln_total      = Math.log([total_samples, 1].max)

        best_id    = (sorted[0]["id"] || sorted[0][:id])
        best_score = -Float::INFINITY

        sorted.each do |action|
          aid = action["id"] || action[:id]
          s   = stats_for(model_per_action, aid)
          n   = [s["samples"].to_i, 1].max
          score = s["mean"].to_f + Math.sqrt((2 * ln_total) / n)
          if score > best_score
            best_score = score
            best_id    = aid
          end
        end

        action = sorted.find { |a| (a["id"] || a[:id]) == best_id }
        { action: action, action_probability: 1.0 }
      end

      # --- Top-level entry ---

      def self.evaluate_bandit(bandit_key, config, context, store)
        model = store.get_model(bandit_key)
        return nil unless model

        algorithm     = config["algorithm"] || config[:algorithm]
        actions       = config["actions"]   || config[:actions]     || []
        explore_rate  = config["explorationRate"] || config[:exploration_rate]
        per_action_map = model.is_a?(BanditModel) ? model.per_action : (model["per_action"] || model[:per_action] || {})

        hash_bucket = Avsb::Core::Hash.murmurhash3("#{bandit_key}:#{bucketing_key_from_context(context)}") % MAX_BUCKET

        case algorithm
        when "epsilon-greedy"
          result            = epsilon_greedy(per_action_map, actions, hash_bucket, exploration_rate: explore_rate&.to_f)
          action            = result[:action]
          action_probability = result[:action_probability]
          optimality_gap    = result[:explore_fired] ? (explore_rate || 0.1) : nil
        when "thompson-sampling"
          result            = thompson_sample(per_action_map, actions, hash_bucket)
          action            = result[:action]
          action_probability = result[:action_probability]
          optimality_gap    = nil
        when "ucb1"
          result            = ucb1(per_action_map, actions)
          action            = result[:action]
          action_probability = result[:action_probability]
          optimality_gap    = nil
        else
          raise ArgumentError, "evaluate_bandit: unknown algorithm #{algorithm}"
        end

        {
          action:             action,
          action_probability: action_probability,
          optimality_gap:     optimality_gap,
          model_version:      model.is_a?(BanditModel) ? model.version : (model["version"] || ""),
        }
      end

      def self.bucketing_key_from_context(ctx)
        return ctx["key"].to_s unless ctx["kind"] == "multi"

        user = ctx["user"]
        user.is_a?(Hash) ? user["key"].to_s : ""
      end
      private_class_method :bucketing_key_from_context
    end
  end
end
