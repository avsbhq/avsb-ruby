# frozen_string_literal: true

require "spec_helper"

# Commerce and alias operators, evaluated through Avsb::Core::Audience so the
# kinded attribute lookup is exercised too. These are the operators an
# e-commerce audience built in the dashboard actually writes, and every one of
# them used to evaluate false on this SDK with no warning.
RSpec.describe "commerce and alias audience operators" do
  def audience(condition)
    { "id" => "aud_1", "rules" => { "id" => "g1", "logic" => "AND",
                                    "conditions" => [condition] } }
  end

  def user(**attrs)
    { "kind" => "user", "key" => "u1" }.merge(attrs.transform_keys(&:to_s))
  end

  def evaluate(condition, context, currency_exponent: nil)
    Avsb::Core::Audience.evaluate_audience(audience(condition), context,
                                          currency_exponent: currency_exponent)
  end

  describe "alias operators" do
    it "treats is as equals" do
      cond = { "type" => "CUSTOM_ATTRIBUTE", "attribute" => "plan", "operator" => "is",
               "value" => "enterprise", "contextKind" => "user" }
      expect(evaluate(cond, user(plan: "enterprise"))).to be true
      expect(evaluate(cond, user(plan: "free"))).to be false
    end

    it "treats is_not as not_equals" do
      cond = { "type" => "CUSTOM_ATTRIBUTE", "attribute" => "plan", "operator" => "is_not",
               "value" => "free", "contextKind" => "user" }
      expect(evaluate(cond, user(plan: "enterprise"))).to be true
      expect(evaluate(cond, user(plan: "free"))).to be false
    end

    it "treats does_not_contain as not_contains" do
      cond = { "type" => "CUSTOM_ATTRIBUTE", "attribute" => "email",
               "operator" => "does_not_contain", "value" => "@acme.com",
               "contextKind" => "user" }
      expect(evaluate(cond, user(email: "a@other.com"))).to be true
      expect(evaluate(cond, user(email: "a@ACME.com"))).to be false
    end

    it "treats does_not_exist as not_exists" do
      cond = { "type" => "CUSTOM_ATTRIBUTE", "attribute" => "betaOptIn",
               "operator" => "does_not_exist", "value" => "", "contextKind" => "user" }
      expect(evaluate(cond, user)).to be true
      expect(evaluate(cond, user(betaOptIn: true))).to be false
    end

    it "misses when the condition names a context kind the context does not carry" do
      # A single user context cannot satisfy an organization-scoped condition,
      # not even does_not_exist: the sub-context is absent, so the condition is
      # not evaluable at all. This guard used to run for multi-contexts only.
      cond = { "type" => "CUSTOM_ATTRIBUTE", "attribute" => "tier",
               "operator" => "does_not_exist", "value" => "",
               "contextKind" => "organization" }
      expect(evaluate(cond, user)).to be false
    end

    it "matches when the named kind is present but the attribute is not" do
      cond = { "type" => "CUSTOM_ATTRIBUTE", "attribute" => "tier",
               "operator" => "does_not_exist", "value" => "",
               "contextKind" => "organization" }
      multi = { "kind" => "multi",
                "user" => { "kind" => "user", "key" => "u1" },
                "organization" => { "kind" => "organization", "key" => "org_1" } }
      expect(evaluate(cond, multi)).to be true
    end

    it "does not match a numeric comparison against a text attribute" do
      cond = { "type" => "CUSTOM_ATTRIBUTE", "attribute" => "plan",
               "operator" => "greater_than", "value" => "-1", "contextKind" => "user" }
      expect(evaluate(cond, user(plan: "enterprise"))).to be false
    end
  end

  describe "CART_VALUE" do
    def cart_condition(operator, value)
      { "type" => "CART_VALUE", "id" => "c", "operator" => operator, "value" => value,
        "contextKind" => "user" }
    end

    it "compares a decimal cart value against a minor-units threshold" do
      # 5000 minor units at exponent 2 is 50.00 major units.
      expect(evaluate(cart_condition("greater_than", "5000"), user(cartValue: 75))).to be true
      expect(evaluate(cart_condition("greater_than", "5000"), user(cartValue: 25))).to be false
    end

    it "treats between as inclusive on both ends" do
      cond = cart_condition("between", %w[5000 10000])
      expect(evaluate(cond, user(cartValue: 50))).to be true
      expect(evaluate(cond, user(cartValue: 100))).to be true
      expect(evaluate(cond, user(cartValue: 100.01))).to be false
    end

    it "honours a zero-exponent currency" do
      cond = cart_condition("greater_than", "25000")
      expect(evaluate(cond, user(cartValue: 25_001), currency_exponent: 0)).to be true
      expect(evaluate(cond, user(cartValue: 25_001))).to be true # exponent 2 default: 250.00
      expect(evaluate(cond, user(cartValue: 100), currency_exponent: 0)).to be false
    end

    it "fails closed when the attribute is missing, mistyped, or the value is not numeric" do
      expect(evaluate(cart_condition("greater_than", "5000"), user)).to be false
      expect(evaluate(cart_condition("greater_than", "5000"), user(cartValue: "75"))).to be false
      expect(evaluate(cart_condition("greater_than", "lots"), user(cartValue: 75))).to be false
      expect(evaluate(cart_condition("between", ["5000"]), user(cartValue: 75))).to be false
    end
  end

  describe "PRODUCTS_VIEWED" do
    def viewed_condition(operator, value, extras = {})
      { "type" => "PRODUCTS_VIEWED", "id" => "c", "operator" => operator, "value" => value,
        "contextKind" => "user" }.merge(extras)
    end

    it "matches viewed_any against the viewedSkus list" do
      cond = viewed_condition("viewed_any", %w[SKU-RED-01 SKU-BLUE-02])
      expect(evaluate(cond, user(viewedSkus: %w[SKU-GREEN-09 SKU-BLUE-02]))).to be true
      expect(evaluate(cond, user(viewedSkus: %w[SKU-GREEN-09]))).to be false
    end

    it "inverts for not_viewed_any" do
      cond = viewed_condition("not_viewed_any", %w[SKU-RED-01])
      expect(evaluate(cond, user(viewedSkus: %w[SKU-GREEN-09]))).to be true
      expect(evaluate(cond, user(viewedSkus: %w[SKU-RED-01]))).to be false
    end

    it "reads viewedCategories when match is category" do
      cond = viewed_condition("viewed_any", %w[shoes], "match" => "category")
      expect(evaluate(cond, user(viewedCategories: %w[shoes]))).to be true
      expect(evaluate(cond, user(viewedSkus: %w[shoes]))).to be false
    end

    it "evaluates false for both operators when the condition is dataset backed" do
      # Dataset windows live in the browser, so the server cannot resolve
      # membership. Degrading to false beats an accidental full-traffic match.
      cond = viewed_condition("viewed_any", %w[SKU-RED-01],
                              "datasetSlug" => "recently-viewed")
      expect(evaluate(cond, user(viewedSkus: %w[SKU-RED-01]))).to be false

      inverted = viewed_condition("not_viewed_any", %w[SKU-RED-01],
                                  "datasetSlug" => "recently-viewed")
      expect(evaluate(inverted, user(viewedSkus: []))).to be false
    end

    it "fails closed with no target list or a mistyped attribute" do
      expect(evaluate(viewed_condition("viewed_any", []), user(viewedSkus: %w[X]))).to be false
      expect(evaluate(viewed_condition("viewed_any", %w[X]), user(viewedSkus: "X"))).to be false
    end
  end

  describe "PURCHASE_HISTORY" do
    def history_condition(operator, value)
      { "type" => "PURCHASE_HISTORY", "id" => "c", "operator" => operator, "value" => value,
        "contextKind" => "user" }
    end

    it "answers has_purchased and has_not_purchased from the profile" do
      buyer = user(purchaseHistory: { "hasPurchased" => true })
      expect(evaluate(history_condition("has_purchased", ""), buyer)).to be true
      expect(evaluate(history_condition("has_not_purchased", ""), buyer)).to be false
    end

    it "makes every operator false when purchaseHistory is absent" do
      # Frozen rule: absence means "not provided", not "never purchased". A
      # server caller owns this data, so we do not guess on its behalf.
      expect(evaluate(history_condition("has_not_purchased", ""), user)).to be false
      expect(evaluate(history_condition("has_purchased", ""), user)).to be false
      expect(evaluate(history_condition("order_count_gt", "0"), user)).to be false
    end

    it "compares lifetime spend against a minor-units threshold" do
      cond = history_condition("lifetime_spend_gt", "25000")
      profile = { "hasPurchased" => true, "lifetimeSpend" => 250.01 }
      expect(evaluate(cond, user(purchaseHistory: profile))).to be true
      expect(evaluate(cond, user(purchaseHistory: profile.merge("lifetimeSpend" => 249)))).to be false
    end

    it "compares order count strictly greater than" do
      cond = history_condition("order_count_gt", "3")
      expect(evaluate(cond, user(purchaseHistory: { "hasPurchased" => true,
                                                    "orderCount" => 4 }))).to be true
      expect(evaluate(cond, user(purchaseHistory: { "hasPurchased" => true,
                                                    "orderCount" => 3 }))).to be false
    end

    it "measures recency against the clock" do
      cond = history_condition("last_purchase_older_than", "30")
      old_profile = { "hasPurchased" => true, "lastPurchaseAt" => 0 }
      recent = { "hasPurchased" => true,
                 "lastPurchaseAt" => (Time.now.to_f * 1000).to_i }
      expect(evaluate(cond, user(purchaseHistory: old_profile))).to be true
      expect(evaluate(cond, user(purchaseHistory: recent))).to be false
    end

    it "is vacuously older only for someone who never purchased" do
      cond = history_condition("last_purchase_older_than", "30")
      never = { "hasPurchased" => false }
      unknown_timestamp = { "hasPurchased" => true }
      expect(evaluate(cond, user(purchaseHistory: never))).to be true
      expect(evaluate(cond, user(purchaseHistory: unknown_timestamp))).to be false
    end
  end
end
