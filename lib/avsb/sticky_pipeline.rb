# frozen_string_literal: true

require_relative "core/types"

module Avsb
  # Sticky bucketing, wired at the CLIENT layer.
  #
  # The evaluator stays a pure function of datafile plus context; sticky
  # assignments are read before it runs and written after it returns, exactly
  # as packages/avsb-node/src/AvsbServer.ts does it. The pipeline order is
  # locked by packages/avsb-conformance/fixtures/semantics/manifest.json:
  #
  #   1. runtime override   (client)
  #   2. sticky lookup      (client)
  #   3. datafile override  (evaluator)
  #   4. holdout            (evaluator)
  #   5. rules, in order    (evaluator)
  #   6. flag default       (evaluator)
  #
  # A sticky_bucket_service used to be accepted by Avsb::Server and never
  # passed anywhere, so configuring a Redis-backed store compiled, ran, and
  # did nothing.
  #
  # The store's assignment Hash is canonically symbol-keyed
  # (+:variation_id+, +:rule_id+, +:ruleType+ as +:rule_type+, +:assigned_at+),
  # which is what the shipped in-memory, Redis, and DynamoDB adapters write.
  # Camel-cased string keys are read too, because a hand-rolled store written
  # against the cross-language contract will use those.
  class StickyPipeline
    # @param service [Object, nil] responds to +lookup+ and +save+
    # @param logger [Object]
    # @param on_orphan [Proc, nil]
    def initialize(service:, logger:, on_orphan: nil)
      @service   = service
      @logger    = logger
      @on_orphan = on_orphan
    end

    # @return [Boolean]
    def enabled?
      !@service.nil?
    end

    # Look up a stored assignment.
    #
    # @param datafile [Hash]
    # @param flag_key [String]
    # @param user_id [String]
    # @param reasons [Array<String>] appended to on a hit
    # @yieldparam assignment [Hash{Symbol=>Object}] the stored assignment
    # @yieldparam variation [Hash] the datafile variation being served
    # @return [Hash{Symbol=>Object}, nil] an evaluator-shaped result on a hit,
    #   nil on a miss. A miss is normal, not an error.
    def lookup(datafile, flag_key, user_id, reasons)
      return nil unless @service

      assignment = read(user_id, flag_key)
      return nil unless assignment && assignment[:variation_id]

      flag = find_flag(datafile, flag_key)
      return nil unless flag

      # An assignment pointing at a deleted variation is a MISS, not an error:
      # the variation is gone, so serving it is impossible.
      variation = (flag["variations"] || []).find { |v| v["id"] == assignment[:variation_id] }
      return nil unless variation

      reasons << "matched sticky bucket assignment for userId=\"#{user_id}\""

      if orphaned_rule?(flag, assignment, variation)
        # Serve the sticky value, but suppress the exposure: the rule it
        # would be attributed to is gone, so the event would land against an
        # experiment that no longer exists.
        @logger.warn(
          "avsb sticky assignment for #{flag_key.inspect} references rule " \
          "#{assignment[:rule_id].inspect}, which no longer serves variation " \
          "#{variation["id"].inspect}. Serving the stored value and skipping the exposure."
        )
        notify_orphan(flag_key, user_id, assignment)
      elsif block_given?
        yield(assignment, variation)
      end

      {
        value:         variation["value"],
        variation_key: variation["key"],
        source:        Core::EvaluationSource::STICKY,
        rule_id:       assignment[:rule_id],
        rule_type:     assignment[:rule_type],
        flag_key:      flag_key,
        reasons:       reasons.dup,
      }
    end

    # Persist an assignment, if this decision is one worth remembering.
    #
    # Only an ab_test rule match is: a targeted_delivery is a rollout, not an
    # assignment, and holdouts, overrides, and defaults are recomputed every
    # time by design.
    #
    # @param datafile [Hash]
    # @param flag_key [String]
    # @param user_id [String]
    # @param result [Hash{Symbol=>Object}] the evaluator result
    # @return [void]
    def save(datafile, flag_key, user_id, result)
      return unless @service
      return unless result[:source] == Core::EvaluationSource::RULE
      return unless result[:rule_type] == Core::RuleType::AB_TEST
      return unless result[:variation_key] && result[:rule_id]

      flag = find_flag(datafile, flag_key)
      return unless flag

      variation = (flag["variations"] || []).find { |v| v["key"] == result[:variation_key] }
      return unless variation

      # The variation's ID, never its key: lookup resolves by id, so saving
      # the key writes a row that can never match again.
      @service.save(user_id, flag_key, {
        variation_id: variation["id"],
        rule_id:      result[:rule_id],
        rule_type:    Core::RuleType::AB_TEST,
        assigned_at:  (Time.now.to_f * 1000).to_i,
      })
      nil
    rescue StandardError => e
      @logger.warn("avsb sticky save failed for #{flag_key.inspect}: #{e.class}: #{e.message}")
      nil
    end

    private

    def read(user_id, flag_key)
      normalise(@service.lookup(user_id, flag_key))
    rescue StandardError => e
      @logger.warn("avsb sticky lookup failed for #{flag_key.inspect}: #{e.class}: #{e.message}")
      nil
    end

    def normalise(assignment)
      return nil unless assignment.is_a?(::Hash)

      {
        variation_id: pick(assignment, :variation_id, "variationId"),
        rule_id:      pick(assignment, :rule_id, "ruleId"),
        rule_type:    pick(assignment, :rule_type, "ruleType"),
        assigned_at:  pick(assignment, :assigned_at, "assignedAt"),
      }
    end

    def pick(assignment, symbol_key, string_key)
      assignment.fetch(symbol_key) do
        assignment.fetch(string_key) { assignment[symbol_key.to_s] }
      end
    end

    def find_flag(datafile, flag_key)
      (datafile["flags"] || []).find { |f| f["key"] == flag_key }
    end

    def orphaned_rule?(flag, assignment, variation)
      rule = (flag["rules"] || []).find { |r| r["id"] == assignment[:rule_id] }
      return true unless rule

      !(rule["variations"] || []).any? { |rv| rv["variationId"] == variation["id"] }
    end

    def notify_orphan(flag_key, user_id, assignment)
      return unless @on_orphan

      @on_orphan.call({ flag_key: flag_key, user_id: user_id, assignment: assignment })
    rescue StandardError => e
      @logger.error("avsb on_sticky_orphan callback raised: #{e.class}: #{e.message}")
    end
  end
end
