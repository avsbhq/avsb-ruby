# frozen_string_literal: true

require_relative "js_value"

module Avsb
  module Core
    # Version-number comparison for the six semver_* audience operators:
    # port of packages/avsb-core/src/semver.ts. Every SDK reads one grammar:
    #
    # * surrounding ASCII whitespace (space, tab, LF, VT, FF, CR) is trimmed;
    # * one optional leading "v" or "V";
    # * one to three dot-separated numeric parts, digits only, no leading
    #   zero unless the part is exactly "0"; a missing minor or patch reads
    #   as 0;
    # * an optional "-prerelease" of dot-separated, non-empty [0-9A-Za-z-]
    #   identifiers, a digits-only one without a leading zero;
    # * an optional "+build" of the same identifiers (leading zeros allowed),
    #   checked and then ignored.
    #
    # Order is SemVer 2.0.0 section 11. Numeric parts compare as digit
    # strings (length first, then byte by byte), the same way in every port.
    # Any unparsable side, or an attribute that is neither a string nor a
    # number, is no match, semver_neq included. Pinned by the
    # operator_semver_* conformance cases.
    #
    # Two Ruby defaults are avoided on purpose: String#strip also removes
    # NUL, and String#split drops trailing empty pieces ("1.2." would read
    # as "1.2", and "" would split into nothing at all).
    #
    # @api private
    module SemVer
      MAX_CORE_PARTS = 3

      OPERATORS = %w[semver_eq semver_neq semver_gt semver_gte semver_lt semver_lte].freeze

      ASCII_WHITESPACE = [" ", "\t", "\n", "\v", "\f", "\r"].freeze

      # A parsed version. Numeric parts are canonical digit strings; build
      # metadata is dropped.
      Parsed = Data.define(:major, :minor, :patch, :prerelease)

      def self.operator?(operator)
        OPERATORS.include?(operator)
      end

      def self.digit_byte?(byte)
        byte.between?(0x30, 0x39)
      end

      def self.identifier_byte?(byte)
        digit_byte?(byte) || byte.between?(0x41, 0x5A) || byte.between?(0x61, 0x7A) || byte == 0x2D
      end

      def self.all_digits?(value)
        !value.empty? && value.each_byte.all? { |byte| digit_byte?(byte) }
      end

      # Digits only, with no leading zero unless the identifier is exactly "0".
      def self.numeric_identifier?(value)
        all_digits?(value) && (value.length == 1 || value[0] != "0")
      end

      # A non-empty run of [0-9A-Za-z-]; any byte outside ASCII fails.
      def self.dot_identifier?(value)
        !value.empty? && value.each_byte.all? { |byte| identifier_byte?(byte) }
      end

      def self.prerelease_identifier?(value)
        dot_identifier?(value) && (!all_digits?(value) || numeric_identifier?(value))
      end

      def self.trim(value)
        start = 0
        finish = value.length
        start += 1 while start < finish && ASCII_WHITESPACE.include?(value[start])
        finish -= 1 while finish > start && ASCII_WHITESPACE.include?(value[finish - 1])
        value[start...finish]
      end

      # Every piece between dots, empty ones included, and always at least one.
      def self.split_dots(value)
        parts = []
        start = 0
        while (dot = value.index(".", start))
          parts << value[start...dot]
          start = dot + 1
        end
        parts << value[start..]
        parts
      end

      # Read a version string.
      # @return [Parsed, nil] nil when +input+ does not follow the grammar
      def self.parse(input)
        return nil unless input.is_a?(String)

        text = trim(input)
        text = text[1..] if text.start_with?("v", "V")

        plus = text.index("+")
        if plus
          return nil unless split_dots(text[(plus + 1)..]).all? { |id| dot_identifier?(id) }

          text = text[0...plus]
        end

        prerelease = []
        dash = text.index("-")
        if dash
          prerelease = split_dots(text[(dash + 1)..])
          return nil unless prerelease.all? { |id| prerelease_identifier?(id) }

          text = text[0...dash]
        end

        parts = split_dots(text)
        return nil if parts.length > MAX_CORE_PARTS
        return nil unless parts.all? { |part| numeric_identifier?(part) }

        Parsed.new(major: parts[0], minor: parts[1] || "0", patch: parts[2] || "0", prerelease: prerelease)
      end

      # Two canonical digit strings, ordered as the integers they spell.
      def self.compare_numeric(left, right)
        return left.length <=> right.length if left.length != right.length

        left <=> right
      end

      def self.compare_prerelease_identifier(left, right)
        left_numeric = all_digits?(left)
        right_numeric = all_digits?(right)
        return compare_numeric(left, right) if left_numeric && right_numeric
        return -1 if left_numeric
        return 1 if right_numeric

        # Both are [0-9A-Za-z-] only, so byte order is ASCII order.
        left <=> right
      end

      # SemVer 2.0.0 precedence.
      # @return [Integer] -1 when +left+ is lower, 1 when higher, 0 when equal
      def self.compare(left, right)
        %i[major minor patch].each do |part|
          order = compare_numeric(left.public_send(part), right.public_send(part))
          return order unless order.zero?
        end

        left_release = left.prerelease.empty?
        right_release = right.prerelease.empty?
        return 0 if left_release && right_release
        return 1 if left_release
        return -1 if right_release

        left.prerelease.zip(right.prerelease).each do |a, b|
          break if a.nil? || b.nil?

          order = compare_prerelease_identifier(a, b)
          return order unless order.zero?
        end
        left.prerelease.length <=> right.prerelease.length
      end

      # The version text of a context attribute: a string as is, a number as
      # JavaScript's String(n) prints it, anything else has none.
      def self.version_text(value)
        return value if value.is_a?(String)
        return JsValue.number_to_s(value) if value.is_a?(Integer) || value.is_a?(Float)

        nil
      end

      # Answer one semver_* condition. +actual+ is the context attribute,
      # +expected+ the rule value (already its first entry when it was a
      # list). Never raises; anything unreadable is false.
      def self.evaluate(operator, actual, expected)
        return false unless operator?(operator)

        actual_text = version_text(actual)
        return false if actual_text.nil? || !expected.is_a?(String)

        actual_version = parse(actual_text)
        expected_version = parse(expected)
        return false if actual_version.nil? || expected_version.nil?

        order = compare(actual_version, expected_version)
        case operator
        when "semver_eq" then order.zero?
        when "semver_neq" then !order.zero?
        when "semver_gt" then order.positive?
        when "semver_gte" then order >= 0
        when "semver_lt" then order.negative?
        when "semver_lte" then order <= 0
        else false
        end
      end

      private_class_method :digit_byte?, :identifier_byte?, :all_digits?, :numeric_identifier?,
                           :dot_identifier?, :prerelease_identifier?, :trim, :split_dots,
                           :compare_numeric, :compare_prerelease_identifier, :version_text
    end
  end
end
