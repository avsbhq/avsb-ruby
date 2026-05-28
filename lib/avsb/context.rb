# frozen_string_literal: true

module Avsb
  # Convenience constructor for a single-context user context.
  # Returns a plain Hash matching the EvalContext wire shape.
  #
  # Example:
  #   ctx = Avsb::SingleContext.new(kind: "user", key: "alice", plan: "pro")
  SingleContext = Data.define(:kind, :key, :name, :_meta, :attributes) do
    # attributes holds extra targeting attributes beyond the reserved keys.
    def initialize(kind:, key:, name: nil, _meta: nil, attributes: {})
      super
    end

    def to_h
      base = { "kind" => kind, "key" => key }
      base["name"]  = name  unless name.nil?
      base["_meta"] = _meta unless _meta.nil?
      attributes.each { |k, v| base[k.to_s] = v }
      base
    end
  end

  # Multi-context container.  +contexts+ is a Hash of kind => SingleContext.
  MultiContext = Data.define(:contexts) do
    def to_h
      base = { "kind" => "multi" }
      contexts.each { |kind, ctx| base[kind.to_s] = ctx.to_h }
      base
    end
  end

  # EvalContext is either a SingleContext or a MultiContext.
  # Internally the SDK always converts to plain Hash (wire shape) before eval.

  module EvalContext
    # Build a user SingleContext quickly.
    def self.user(key, **attrs)
      SingleContext.new(kind: "user", key: key, attributes: attrs.transform_keys(&:to_s))
    end

    # Wrap a plain Hash as an eval context (pass-through for JSON-loaded data).
    def self.from_hash(h)
      h
    end
  end
end
