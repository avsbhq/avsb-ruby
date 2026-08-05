# frozen_string_literal: true

module Avsb
  module Core
    # JavaScript value semantics, implemented deliberately instead of Ruby's.
    #
    # The reference evaluator is the TypeScript engine in @avsbhq/core, so
    # JavaScript's rules are the cross-language contract
    # (packages/avsb-conformance/fixtures/semantics/manifest.json). Ruby
    # disagrees with JavaScript in two places that matter, and both would
    # silently change what a flag answers:
    #
    #   * Truthiness. Ruby calls 0 and "" true. JavaScript calls them false.
    #   * Numeric coercion. Ruby's String#to_f turns "abc" into 0.0.
    #     JavaScript's Number("abc") is NaN, and every comparison against
    #     NaN is false.
    #
    # Nothing in this SDK may use `!!value` for a flag value or `.to_f` for
    # an audience comparison. Use these helpers.
    #
    # @api private
    module JsValue
      # Values JavaScript treats as falsy: false, 0, -0, NaN, "", null,
      # undefined. Everything else is truthy, including "0", "false", [],
      # and {}.
      #
      # @param value [Object] any evaluated flag value
      # @return [Boolean] true when JavaScript would treat +value+ as truthy
      def self.truthy?(value)
        case value
        when nil, false then false
        when Float      then !value.zero? && !value.nan?
        when Numeric    then !value.zero?
        when String     then !value.empty?
        else true
        end
      end

      # JavaScript's Number(value), for audience comparison operators.
      #
      # Returns nil where JavaScript returns NaN, because NaN comparisons
      # are all false and nil forces the caller to say so explicitly.
      #
      # Deliberate divergence: a missing attribute arrives here as nil.
      # JavaScript distinguishes undefined (NaN) from null (0); Ruby has one
      # nil, and treating it as NaN is the fail-closed reading. A rule
      # comparing a missing attribute never matches.
      #
      # @param value [Object] attribute value or condition value
      # @return [Float, nil] the numeric value, or nil for "not a number"
      def self.number(value)
        case value
        when nil        then nil
        when true       then 1.0
        when false      then 0.0
        when Float      then value.nan? ? nil : value
        when Numeric    then value.to_f
        when String     then number_from_string(value)
        else nil
        end
      end

      # True when both sides coerce to real numbers. JavaScript comparisons
      # involving NaN are always false, so callers gate on this.
      #
      # @param left [Object]
      # @param right [Object]
      # @return [Array(Float, Float), nil] the pair, or nil when either is NaN
      def self.number_pair(left, right)
        a = number(left)
        return nil if a.nil?

        b = number(right)
        return nil if b.nil?

        [a, b]
      end

      # JavaScript's String(number), used for reason strings.
      #
      # The conformance corpus records reason text exactly, including
      # threshold numbers: "threshold 1000" and "threshold 1234.5". Ruby's
      # Float#to_s would print "1000.0" there and break every boundary
      # fixture, so integral floats print without a decimal point.
      #
      # @param value [Numeric] a threshold or cumulative bucket boundary
      # @return [String] the JavaScript rendering of +value+
      def self.number_to_s(value)
        return value.to_s if value.is_a?(Integer)

        f = value.to_f
        return "NaN" if f.nan?
        return f.positive? ? "Infinity" : "-Infinity" if f.infinite?
        # 1e21 is where JavaScript switches to exponential notation; below
        # it an integral double prints as a plain integer.
        return f.to_i.to_s if f == f.truncate && f.abs < 1e21

        f.to_s
      end

      # Parse the numeric string forms JavaScript's Number() accepts.
      # Whitespace-only and empty strings are 0, as in JavaScript.
      def self.number_from_string(str)
        trimmed = str.strip
        return 0.0 if trimmed.empty?
        return Float::INFINITY  if trimmed == "Infinity" || trimmed == "+Infinity"
        return -Float::INFINITY if trimmed == "-Infinity"

        begin
          Float(trimmed)
        rescue ArgumentError, TypeError
          nil
        end
      end
      private_class_method :number_from_string
    end
  end
end
