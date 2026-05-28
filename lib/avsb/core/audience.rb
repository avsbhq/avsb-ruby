# frozen_string_literal: true

require_relative "hash"

module Avsb
  module Core
    # Server-side audience evaluator — evaluates only CUSTOM_ATTRIBUTE conditions.
    # Browser-detected conditions (DEVICE, BROWSER, PLATFORM, LANGUAGE, COOKIE,
    # QUERY_PARAM) always return false on the server — the Ruby SDK is server-only.
    module Audience
      RESERVED_KEYS = %w[kind key name _meta].freeze

      # Evaluate a FlagDatafileAudience Hash against a context Hash.
      def self.evaluate_audience(audience, context)
        return true if audience.nil? || audience["rules"].nil?

        evaluate_group(audience["rules"], context)
      end

      # Evaluate a ConditionGroup Hash.
      def self.evaluate_group(group, context)
        return true if group.nil?

        conditions = group["conditions"]
        return true if conditions.nil? || conditions.empty?

        if group["logic"] == "AND"
          conditions.all? { |item| evaluate_item(item, context) }
        else
          conditions.any? { |item| evaluate_item(item, context) }
        end
      end

      # Route to group or condition evaluation.
      def self.evaluate_item(item, context)
        if item.key?("logic") && item.key?("conditions")
          evaluate_group(item, context)
        else
          evaluate_condition(item, context)
        end
      end

      # Evaluate a single Condition Hash.
      def self.evaluate_condition(condition, context)
        case condition["type"]
        when "CUSTOM_ATTRIBUTE"
          eval_custom_attribute(condition, context)
        else
          # Browser-detected or unknown condition types return false server-side.
          false
        end
      end

      # --- Custom attribute evaluation ---

      def self.eval_custom_attribute(condition, context)
        attr_key = condition["attribute"]
        return false if attr_key.nil? || attr_key.empty?

        context_kind = condition["contextKind"]

        # When contextKind is declared, the sub-context must exist.
        if context_kind && multi_context?(context)
          return false unless context[context_kind]
        end

        actual   = resolve_attribute(context, context_kind, attr_key)
        raw_val  = condition["value"]
        expected = raw_val.is_a?(Array) ? raw_val[0] : raw_val

        case condition["operator"]
        when "exists"
          !actual.nil?
        when "not_exists"
          actual.nil?
        when "equals"
          actual.to_s == expected.to_s
        when "not_equals"
          actual.to_s != expected.to_s
        when "contains"
          actual.to_s.downcase.include?(expected.to_s.downcase)
        when "not_contains"
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
        when "greater_than"
          actual.to_f > expected.to_f
        when "less_than"
          actual.to_f < expected.to_f
        when "gte"
          actual.to_f >= expected.to_f
        when "lte"
          actual.to_f <= expected.to_f
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

      # --- Context resolution helpers ---

      def self.multi_context?(context)
        context.is_a?(Hash) && context["kind"] == "multi"
      end

      # Resolve a (context_kind, attribute) pair from the context Hash.
      def self.resolve_attribute(context, context_kind, attribute)
        if multi_context?(context)
          if context_kind
            sub = context[context_kind]
            return nil unless sub.is_a?(Hash)

            read_sub_attribute(sub, attribute)
          else
            # No contextKind — fall back to 'user' sub-context or primary.
            sub = context["user"]
            return nil unless sub.is_a?(Hash)

            return sub["key"] if attribute == "userId"

            read_sub_attribute(sub, attribute)
          end
        else
          # Single context.
          return context["key"] if attribute == "userId"

          read_sub_attribute(context, attribute)
        end
      end

      def self.read_sub_attribute(sub, attribute)
        return sub["key"]  if attribute == "key"
        return sub["name"] if attribute == "name"
        return nil         if RESERVED_KEYS.include?(attribute)

        sub[attribute]
      end
    end
  end
end
