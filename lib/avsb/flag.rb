# frozen_string_literal: true

require_relative "core/types"
require_relative "core/js_value"

module Avsb
  # Flag: the result of one evaluation.
  #
  # Every +get_*_flag+ call returns this object. Signatures:
  #
  #   value           #=> Object          the evaluated value, your type
  #   variation_key   #=> String, nil     nil for default, not_found, not_ready
  #   source          #=> String          one of Avsb::Core::EvaluationSource::ALL
  #   rule_id         #=> String, nil     the rule or holdout that decided
  #   rule_type       #=> String, nil     "ab_test", "targeted_delivery",
  #                                       "holdout", "bandit", or nil
  #   reasons         #=> Array<String>   frozen decision trail, in order
  #   evaluated_at    #=> Integer         milliseconds since the Unix epoch
  #   duration_micros #=> Integer         microseconds spent in the evaluator
  #   enabled?        #=> true, false
  #   exists?         #=> true, false
  class Flag
    attr_reader :value, :variation_key, :source, :rule_id, :rule_type, :reasons,
                :evaluated_at, :duration_micros

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

    # True when a real decision produced this value AND the value is truthy.
    #
    # Both halves matter, and both are cross-language locks:
    #
    #   * "A real decision" means one of rule, holdout, bandit,
    #     runtimeOverride, datafileOverride, sticky. A flag serving its
    #     default variation is NOT enabled however truthy that default is,
    #     and an uninitialised SDK is never enabled.
    #   * "Truthy" means JavaScript truthy, because the reference evaluator is
    #     the TypeScript engine. Ruby would call 0 and "" true; this does not.
    #     The string "0" and the string "false" ARE truthy. Do not parse them.
    #
    # @return [Boolean]
    def enabled?
      Core::EvaluationSource::DECIDED.include?(@source) && Core::JsValue.truthy?(@value)
    end

    alias enabled enabled?

    # True when the flag key is known to exist in the datafile.
    #
    # False for not_found and for not_ready. A disabled flag exists: the
    # customer turned it off, which is not the same as it being absent. With
    # no datafile loaded, existence is unknowable, so the honest answer is
    # false rather than a guess.
    #
    # @return [Boolean]
    def exists?
      !Core::EvaluationSource::UNKNOWN.include?(@source)
    end

    alias exists exists?

    # @return [Hash{Symbol=>Object}]
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
      "#<Avsb::Flag value=#{@value.inspect} source=#{@source.inspect} " \
        "variation_key=#{@variation_key.inspect}>"
    end

    # Build a Flag from the raw Hash returned by the evaluator.
    #
    # @param result [Hash{Symbol=>Object}] an Evaluator.evaluate_flag result
    # @param evaluated_at [Integer, nil] ms epoch, defaults to now
    # @param duration_micros [Integer]
    # @return [Avsb::Flag]
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
