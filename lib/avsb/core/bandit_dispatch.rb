# frozen_string_literal: true

require_relative "bandits"

module Avsb
  module Core
    # Resolution of `bandit`-typed rules for the evaluator.
    #
    # Mirrors the resolveRuleBandit / coldStartBanditStore pair in
    # packages/avsb-core/src/evaluate.ts. Kept out of evaluate.rb so the
    # evaluator stays readable; the semantics live here.
    #
    # Bandit models are learned client-layer state, not published in the
    # datafile, so an SDK with no model store still has to decide something.
    # It runs the algorithm's documented cold-start policy against a
    # zero-observation model rather than skipping the rule: a configured
    # bandit that silently behaves as "no rules matched" is the silent drop
    # the spec bans (section 1.2). The conformance corpus locks the
    # cold-start action for every algorithm.
    #
    # @api private
    module BanditDispatch
      # Model version reported for the store-free cold-start fallback.
      COLD_START_MODEL_VERSION = "cold-start"

      # Hands back a zero-observation model for any bandit key.
      #
      # Duck-types the store contract (+get_model+ / +update_model+) that
      # Bandits.evaluate_bandit consumes.
      class ColdStartStore
        # @param algorithm [String] the bandit algorithm from the datafile
        def initialize(algorithm)
          @model = Bandits::BanditModel.new(
            version: COLD_START_MODEL_VERSION,
            algorithm: algorithm,
            per_action: {},
          )
        end

        # @param _bandit_key [String]
        # @return [Avsb::Core::Bandits::BanditModel] the zero-observation model
        def get_model(_bandit_key)
          @model
        end

        # The cold-start model is derived, not stored, so writes are dropped.
        # @return [nil]
        def update_model(_bandit_key, _model)
          nil
        end
      end

      # Resolve the bandit a `bandit`-typed rule points at.
      #
      # A shared +banditId+ (joined against +datafile["bandits"]+) wins over
      # an inline +rule["bandit"]+, and the resolved key is what addresses
      # the model store: the shared entry's key, or the rule's own id for an
      # inline config.
      #
      # @param rule [Hash] the datafile rule
      # @param datafile [Hash] the datafile
      # @return [Hash{Symbol=>Object}, nil] +{key:, config:}+, or nil when
      #   the rule carries neither a resolvable banditId nor an inline config
      def self.resolve_rule_bandit(rule, datafile)
        bandit_id = rule["banditId"]
        if bandit_id
          shared = (datafile["bandits"] || []).find { |b| b["id"] == bandit_id }
          return nil unless shared

          return { key: shared["key"], config: shared["config"] }
        end

        inline = rule["bandit"]
        return { key: rule["id"], config: inline } if inline

        nil
      end

      # Build the store the evaluator hands to the bandit engine.
      #
      # @param config [Hash] the resolved bandit config
      # @param supplied_store [Object, nil] a caller-supplied model store
      # @return [Object] the supplied store, or a cold-start store
      def self.store_for(config, supplied_store)
        return supplied_store if supplied_store

        ColdStartStore.new(config["algorithm"] || config[:algorithm])
      end
    end
  end
end
