# frozen_string_literal: true

module Avsb
  # Unified flag evaluation result (§2.2).
  #
  # Wraps the raw Hash returned by Core::Evaluator.evaluate_flag and
  # exposes a typed, method-based interface plus convenience predicates.
  class Flag
    attr_reader :value, :variation_key, :source, :rule_id, :rule_type, :reasons, :evaluated_at, :duration_micros

    def initialize(value:, variation_key:, source:, rule_id:, rule_type:, reasons:,
                   evaluated_at: nil, duration_micros: 0)
      @value          = value
      @variation_key  = variation_key
      @source         = source
      @rule_id        = rule_id
      @rule_type      = rule_type
      @reasons        = reasons.frozen? ? reasons : reasons.dup.freeze
      @evaluated_at   = evaluated_at || (Time.now.to_f * 1000).to_i
      @duration_micros = duration_micros
    end

    # True when served by a rule and the value is truthy.
    def enabled?
      source == "rule" && !!value
    end

    alias enabled enabled?

    # True when the flag was found in the datafile (source != 'not_found').
    def exists?
      source != "not_found"
    end

    alias exists exists?

    def to_h
      {
        value:           @value,
        variation_key:   @variation_key,
        source:          @source,
        rule_id:         @rule_id,
        rule_type:       @rule_type,
        reasons:         @reasons,
        evaluated_at:    @evaluated_at,
        duration_micros: @duration_micros,
      }
    end

    def inspect
      "#<Avsb::Flag value=#{@value.inspect} source=#{@source.inspect} variation_key=#{@variation_key.inspect}>"
    end

    # Build a Flag from the raw Hash returned by the evaluator.
    def self.from_result(result, evaluated_at: nil, duration_micros: 0)
      new(
        value:           result[:value],
        variation_key:   result[:variation_key],
        source:          result[:source],
        rule_id:         result[:rule_id],
        rule_type:       result[:rule_type],
        reasons:         result[:reasons] || [],
        evaluated_at:    evaluated_at,
        duration_micros: duration_micros,
      )
    end
  end
end
