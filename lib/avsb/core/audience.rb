# frozen_string_literal: true

require_relative "hash"
require_relative "js_value"
require_relative "context_resolver"
require_relative "audience_commerce"

module Avsb
  module Core
    # Audience evaluator: port of packages/avsb-core/src/audience.ts.
    #
    # Evaluates CUSTOM_ATTRIBUTE and the three commerce condition types.
    # Browser-detected conditions (DEVICE, BROWSER, PLATFORM, LANGUAGE,
    # COOKIE, QUERY_PARAM) always return false here: this SDK runs on the
    # server, where there is no navigator, no cookie jar, and no query
    # string to read.
    #
    # Context reading is delegated to Avsb::Core::ContextResolver so audience
    # matching, rule bucketing, and holdouts cannot drift apart. This module
    # used to carry its own copy, and that copy is where the multi-context bug
    # lived: Avsb::Core::Hash (murmur) shadows Ruby's ::Hash in this namespace,
    # so `is_a?(Hash)` was always false and every kinded condition missed.
    module Audience
      # Evaluate a FlagDatafileAudience Hash against a context Hash.
      #
      # @param audience [Hash, nil]
      # @param context [Hash]
      # @param currency_exponent [Integer, nil] datafile currencyExponent,
      #   used by the money-valued commerce operators
      # @return [Boolean]
      def self.evaluate_audience(audience, context, currency_exponent: nil)
        return true if audience.nil? || audience["rules"].nil?

        evaluate_group(audience["rules"], context, currency_exponent: currency_exponent)
      end

      # Evaluate a ConditionGroup Hash.
      # @return [Boolean]
      def self.evaluate_group(group, context, currency_exponent: nil)
        return true if group.nil?

        conditions = group["conditions"]
        return true if conditions.nil? || conditions.empty?

        if group["logic"] == "AND"
          conditions.all? { |item| evaluate_item(item, context, currency_exponent) }
        else
          conditions.any? { |item| evaluate_item(item, context, currency_exponent) }
        end
      end

      # Route to group or condition evaluation.
      # @return [Boolean]
      def self.evaluate_item(item, context, currency_exponent = nil)
        if item.key?("logic") && item.key?("conditions")
          evaluate_group(item, context, currency_exponent: currency_exponent)
        else
          evaluate_condition(item, context, currency_exponent: currency_exponent)
        end
      end

      # Evaluate a single Condition Hash.
      # @return [Boolean]
      def self.evaluate_condition(condition, context, currency_exponent: nil)
        type = condition["type"]
        return eval_custom_attribute(condition, context) if type == "CUSTOM_ATTRIBUTE"

        if AudienceCommerce.commerce_type?(type)
          context_kind = condition["contextKind"]
          return AudienceCommerce.evaluate_condition(
            condition, currency_exponent: currency_exponent
          ) { |attribute| resolve_attribute(context, context_kind, attribute) }
        end

        # Browser-detected or unknown condition types return false server-side.
        false
      end

      # --- Custom attribute evaluation ---

      def self.eval_custom_attribute(condition, context)
        attr_key = condition["attribute"]
        return false if attr_key.nil? || attr_key.empty?

        context_kind = condition["contextKind"]

        # When the condition names a context kind, that sub-context must
        # exist for the condition to be evaluable at all. A missing kind is a
        # hard no-match, which is NOT the same as a missing attribute (a
        # missing attribute still matches does_not_exist). This guard used to
        # run only for multi-contexts, so a single user context silently
        # satisfied an organization-scoped does_not_exist condition.
        if context_kind && ContextResolver.get_context_by_kind(context, context_kind).nil?
          return false
        end

        actual   = resolve_attribute(context, context_kind, attr_key)
        raw_val  = condition["value"]
        expected = raw_val.is_a?(Array) ? raw_val[0] : raw_val

        # Alias operators (is, is_not, does_not_contain, does_not_exist) are
        # the names the dashboard audience builder writes for the
        # device/browser condition types, and they reach CUSTOM_ATTRIBUTE
        # conditions too. Before they were implemented, an audience saved
        # with `is` fell through to the default branch and matched nobody.
        case condition["operator"]
        when "exists"
          !actual.nil?
        when "not_exists", "does_not_exist"
          actual.nil?
        when "equals", "is"
          actual.to_s == expected.to_s
        when "not_equals", "is_not"
          actual.to_s != expected.to_s
        when "contains"
          actual.to_s.downcase.include?(expected.to_s.downcase)
        when "not_contains", "does_not_contain"
          !actual.to_s.downcase.include?(expected.to_s.downcase)
        when "starts_with"
          actual.to_s.downcase.start_with?(expected.to_s.downcase)
        when "ends_with"
          actual.to_s.downcase.end_with?(expected.to_s.downcase)
        when "regex"
          begin
            Regexp.new(expected.to_s, Regexp::IGNORECASE).match?(actual.to_s)
          rescue RegexpError
            false
          end
        when "greater_than" then compare_numbers(actual, expected) { |a, b| a > b }
        when "less_than"    then compare_numbers(actual, expected) { |a, b| a < b }
        when "gte"          then compare_numbers(actual, expected) { |a, b| a >= b }
        when "lte"          then compare_numbers(actual, expected) { |a, b| a <= b }
        when "in_list"
          list = raw_val.is_a?(Array) ? raw_val : [raw_val]
          list.any? { |v| actual.to_s == v.to_s }
        when "not_in_list"
          list = raw_val.is_a?(Array) ? raw_val : [raw_val]
          list.none? { |v| actual.to_s == v.to_s }
        else
          false
        end
      end

      # Numeric comparison with JavaScript semantics: when either side is not
      # a number the comparison is false. Ruby's String#to_f would turn "abc"
      # into 0.0 and make `greater_than -1` match a text attribute.
      def self.compare_numbers(actual, expected)
        pair = JsValue.number_pair(actual, expected)
        return false unless pair

        yield(pair[0], pair[1])
      end
      private_class_method :compare_numbers

      # --- Context resolution helpers ---

      # Resolve a (context_kind, attribute) pair from the context Hash.
      #
      # @param context [Hash]
      # @param context_kind [String, nil] the condition's contextKind
      # @param attribute [String]
      # @return [Object, nil]
      def self.resolve_attribute(context, context_kind, attribute)
        if context_kind
          sub = ContextResolver.get_context_by_kind(context, context_kind)
          return nil unless sub

          return ContextResolver.read_sub_attribute(sub, attribute)
        end

        # No contextKind on the condition: fall back to the primary context,
        # which is the `user` sub-context of a multi-context container or the
        # single context itself.
        primary = if ContextResolver.multi_context?(context)
                    ContextResolver.get_context_by_kind(context, "user")
                  else
                    context
                  end
        return nil unless primary

        return primary["key"] if attribute == "userId"

        ContextResolver.read_sub_attribute(primary, attribute)
      end
    end
  end
end
