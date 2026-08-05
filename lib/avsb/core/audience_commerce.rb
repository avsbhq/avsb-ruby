# frozen_string_literal: true

require_relative "js_value"

module Avsb
  module Core
    # Commerce audience conditions: CART_VALUE, PRODUCTS_VIEWED,
    # PURCHASE_HISTORY.
    #
    # Port of packages/avsb-core/src/audienceCommerce.ts. Attributes are
    # resolved by the caller (audience.rb) through the same kinded lookup
    # CUSTOM_ATTRIBUTE uses, so this module receives a resolver block and
    # stays free of context-shape concerns.
    #
    # Every "cannot know" path evaluates to false: a missing or mistyped
    # attribute, a non-numeric condition value, dataset-backed membership,
    # or an unknown operator. Nothing here raises.
    #
    # An e-commerce audience built in the dashboard used to evaluate false
    # on every server SDK with no warning; these operators are the fix, and
    # the operator_commerce_* conformance cases lock them.
    #
    # @api private
    module AudienceCommerce
      DEFAULT_CURRENCY_EXPONENT = 2
      MS_PER_DAY = 86_400_000

      # Evaluate one commerce condition.
      #
      # @param condition [Hash] the datafile condition
      # @param currency_exponent [Integer, nil] the datafile's
      #   +currencyExponent+; 2 when absent or invalid
      # @yieldparam attribute [String] the attribute name to resolve
      # @yieldreturn [Object, nil] the attribute value from the context
      # @return [Boolean]
      def self.evaluate_condition(condition, currency_exponent: nil, &get_attribute)
        exponent = normalise_exponent(currency_exponent)

        case condition["type"]
        when "CART_VALUE"       then eval_cart_value(condition, exponent, &get_attribute)
        when "PRODUCTS_VIEWED"  then eval_products_viewed(condition, &get_attribute)
        when "PURCHASE_HISTORY" then eval_purchase_history(condition, exponent, &get_attribute)
        else false
        end
      end

      # True for the three condition types this module owns.
      # @param type [String, nil]
      # @return [Boolean]
      def self.commerce_type?(type)
        type == "CART_VALUE" || type == "PRODUCTS_VIEWED" || type == "PURCHASE_HISTORY"
      end

      # --- CART_VALUE ---

      def self.eval_cart_value(condition, exponent, &get_attribute)
        actual = get_attribute.call("cartValue")
        # cartValue is a decimal major-units number. Anything else is
        # mistyped and fails closed (a numeric STRING included: the caller
        # controls this attribute, so a string means the wrong data).
        return false unless numeric?(actual)

        actual = actual.to_f

        if condition["operator"] == "between"
          raw = condition["value"]
          return false unless raw.is_a?(Array) && raw.length >= 2

          lower = minor_to_major(raw[0], exponent)
          upper = minor_to_major(raw[1], exponent)
          return false if lower.nil? || upper.nil?

          # between is inclusive on both ends.
          return actual >= lower && actual <= upper
        end

        threshold = minor_to_major(single_value(condition), exponent)
        return false if threshold.nil?

        case condition["operator"]
        when "greater_than" then actual > threshold
        when "gte"          then actual >= threshold
        when "less_than"    then actual < threshold
        when "lte"          then actual <= threshold
        else false
        end
      end
      private_class_method :eval_cart_value

      # --- PRODUCTS_VIEWED ---

      def self.eval_products_viewed(condition, &get_attribute)
        # Dataset-backed membership cannot be resolved server-side: dataset
        # windows live in the browser. Both operators evaluate false, because
        # degrading to false beats an accidental full-traffic match.
        dataset_slug = condition["datasetSlug"]
        return false if dataset_slug.is_a?(String) && !dataset_slug.empty?

        # `match` picks which attribute array is consulted. `window` is
        # ignored server-side: the caller supplies whatever view list it
        # considers current.
        attribute_name = condition["match"] == "category" ? "viewedCategories" : "viewedSkus"
        actual = get_attribute.call(attribute_name)
        return false unless actual.is_a?(Array)

        viewed  = actual.select { |v| v.is_a?(String) }
        raw     = condition["value"]
        list    = raw.is_a?(Array) ? raw : [raw]
        targets = list.select { |v| v.is_a?(String) && !v.empty? }
        # No membership source: both operators false.
        return false if targets.empty?

        any_viewed = targets.any? { |t| viewed.include?(t) }
        case condition["operator"]
        when "viewed_any"     then any_viewed
        when "not_viewed_any" then !any_viewed
        else false
        end
      end
      private_class_method :eval_products_viewed

      # --- PURCHASE_HISTORY ---

      def self.eval_purchase_history(condition, exponent, &get_attribute)
        raw = get_attribute.call("purchaseHistory")
        # A completely absent purchaseHistory makes ALL operators false,
        # including has_not_purchased. Server callers own their data:
        # absence means "not provided", not "never purchased". Mistyped
        # values fail closed the same way.
        return false unless raw.is_a?(::Hash)

        has_purchased = raw["hasPurchased"]
        return false unless has_purchased.is_a?(TrueClass) || has_purchased.is_a?(FalseClass)

        case condition["operator"]
        when "has_purchased"     then has_purchased
        when "has_not_purchased" then !has_purchased
        when "last_purchase_older_than"
          days = numeric_value(single_value(condition))
          return false if days.nil?

          last_purchase_at = raw["lastPurchaseAt"]
          if numeric?(last_purchase_at)
            return last_purchase_at.to_f < now_ms - (days * MS_PER_DAY)
          end

          # No usable purchase timestamp: vacuously older only when the
          # visitor has never purchased. A purchaser with an unknown
          # timestamp is a "cannot know" and evaluates false.
          !has_purchased
        when "lifetime_spend_gt"
          threshold = minor_to_major(single_value(condition), exponent)
          return false if threshold.nil?

          spend = raw["lifetimeSpend"]
          return false unless numeric?(spend)

          spend.to_f > threshold
        when "order_count_gt"
          minimum = numeric_value(single_value(condition))
          return false if minimum.nil?

          count = raw["orderCount"]
          return false unless numeric?(count)

          count.to_f > minimum
        else false
        end
      end
      private_class_method :eval_purchase_history

      # --- helpers ---

      # Milliseconds since the Unix epoch. Extracted so a test can stub the
      # clock for last_purchase_older_than.
      # @return [Integer]
      def self.now_ms
        (Time.now.to_f * 1000).to_i
      end

      def self.normalise_exponent(exponent)
        return exponent if exponent.is_a?(Integer) && exponent >= 0

        DEFAULT_CURRENCY_EXPONENT
      end
      private_class_method :normalise_exponent

      # Money on a condition is a minor-units integer STRING (contract C1).
      # A non-string, or a string that is not a number, means the condition
      # cannot be evaluated.
      def self.minor_to_major(raw, exponent)
        return nil unless raw.is_a?(String) && !raw.strip.empty?

        minor = JsValue.number(raw)
        return nil if minor.nil? || minor.infinite?

        minor / (10.0**exponent)
      end
      private_class_method :minor_to_major

      # Plain numeric condition values (days, counts) are also strings.
      def self.numeric_value(raw)
        return nil unless raw.is_a?(String) && !raw.strip.empty?

        value = JsValue.number(raw)
        return nil if value.nil? || value.infinite?

        value
      end
      private_class_method :numeric_value

      def self.numeric?(value)
        return false unless value.is_a?(Numeric)
        return false if value.is_a?(Float) && (value.nan? || value.infinite?)

        true
      end
      private_class_method :numeric?

      def self.single_value(condition)
        raw = condition["value"]
        raw.is_a?(Array) ? raw[0] : raw
      end
      private_class_method :single_value
    end
  end
end
