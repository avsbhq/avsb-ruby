# frozen_string_literal: true

require "spec_helper"

RSpec.describe Avsb::EvalContext do
  describe ".user" do
    it "builds a single user context with the correct kind and key" do
      ctx = described_class.user("alice")
      expect(ctx.kind).to eq("user")
      expect(ctx.key).to  eq("alice")
    end

    it "attaches extra attributes to the context" do
      ctx = described_class.user("bob", plan: "pro", country: "US")
      expect(ctx.attributes["plan"]).to    eq("pro")
      expect(ctx.attributes["country"]).to eq("US")
    end

    it "produces a Hash via #to_h with string keys" do
      ctx = described_class.user("charlie", age: 30)
      h   = ctx.to_h
      expect(h["kind"]).to eq("user")
      expect(h["key"]).to  eq("charlie")
      expect(h["age"]).to  eq(30)
    end
  end
end

RSpec.describe Avsb::SingleContext do
  it "stores kind and key" do
    ctx = Avsb::SingleContext.new(kind: "organization", key: "org_acme")
    expect(ctx.kind).to eq("organization")
    expect(ctx.key).to  eq("org_acme")
  end

  it "includes optional name in to_h" do
    ctx = Avsb::SingleContext.new(kind: "user", key: "u1", name: "Alice")
    h   = ctx.to_h
    expect(h["name"]).to eq("Alice")
  end

  it "omits nil name from to_h" do
    ctx = Avsb::SingleContext.new(kind: "user", key: "u1")
    h   = ctx.to_h
    expect(h).not_to have_key("name")
  end
end

RSpec.describe Avsb::MultiContext do
  it "builds a multi-context hash with kind=multi" do
    user_ctx = Avsb::SingleContext.new(kind: "user", key: "u1")
    org_ctx  = Avsb::SingleContext.new(kind: "organization", key: "org_acme",
                                        attributes: { "tier" => "enterprise" })
    multi    = Avsb::MultiContext.new(contexts: { "user" => user_ctx, "organization" => org_ctx })
    h        = multi.to_h
    expect(h["kind"]).to          eq("multi")
    expect(h["user"]["key"]).to   eq("u1")
    expect(h["organization"]["tier"]).to eq("enterprise")
  end
end
