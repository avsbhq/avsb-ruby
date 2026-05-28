# frozen_string_literal: true

module Avsb
  # A single decision log entry (§2.5).
  DecisionLogEntry = Data.define(
    :flag_key,
    :value,
    :variation_key,
    :source,
    :rule_id,
    :rule_type,
    :reasons,
    :evaluated_at,
    :duration_micros,
    :context_summary,
    :manually_fired
  ) do
    def initialize(flag_key:, value:, variation_key:, source:, rule_id:, rule_type:,
                   reasons:, evaluated_at:, duration_micros: 0, context_summary: [],
                   manually_fired: false)
      super
    end

    # Redact private attributes from the entry.
    # +private_attrs+ is an Array of attribute key strings to redact.
    def redact(private_attrs)
      return self if private_attrs.nil? || private_attrs.empty?

      redacted_reasons = reasons.map do |r|
        private_attrs.reduce(r) { |s, attr| s.gsub(attr, "[REDACTED]") }
      end

      with(reasons: redacted_reasons)
    end
  end

  # Ordered collection of decision log entries (§2.5).
  class DecisionLog
    attr_reader :entries

    def initialize
      @entries = []
    end

    def record(entry)
      @entries << entry
      nil
    end

    def clear
      @entries.clear
    end

    def to_a
      @entries.dup
    end
  end
end
