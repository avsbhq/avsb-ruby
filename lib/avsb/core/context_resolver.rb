# frozen_string_literal: true

module Avsb
  module Core
    # Reading an EvalContext: kinds, keys, and dotted attribute paths.
    #
    # Port of the context helpers in packages/avsb-core/src/context.ts plus
    # resolveDottedAttribute from evaluate.ts. Split out of the evaluator
    # because audience matching, holdout bucketing, and the client's visitor-id
    # selection all need the same rules.
    #
    # `::Hash` is deliberate throughout: Avsb::Core::Hash (MurmurHash3) shadows
    # Ruby's ::Hash inside this namespace, and a bare `is_a?(Hash)` is
    # therefore always false. That was the bug that made every multi-context
    # lookup silently miss.
    module ContextResolver
      # Attribute names that address built-in fields or SDK metadata, never a
      # targeting attribute.
      RESERVED_KEYS = %w[kind key name _meta].freeze

      class << self
        # @param ctx [Object]
        # @return [Boolean] true for a multi-context container
        def multi_context?(ctx)
          ctx.is_a?(::Hash) && ctx["kind"] == "multi"
        end

        # The sub-context declaring +kind+, or nil.
        #
        # A single context matches only when its own kind matches, so an
        # organization-scoped rule cannot accidentally read a user context.
        #
        # @param ctx [Hash]
        # @param kind [String]
        # @return [Hash, nil]
        def get_context_by_kind(ctx, kind)
          if multi_context?(ctx)
            candidate = ctx[kind]
            return nil unless candidate.is_a?(::Hash)
            return nil unless candidate["kind"] == kind

            candidate
          else
            ctx.is_a?(::Hash) && ctx["kind"] == kind ? ctx : nil
          end
        end

        # The bucketing key for +kind+, or "" when that kind is absent.
        # @param ctx [Hash]
        # @param kind [String]
        # @return [String]
        def bucketing_key(ctx, kind = "user")
          sub = get_context_by_kind(ctx, kind)
          sub ? sub["key"].to_s : ""
        end

        # The primary single context: the `user` sub-context of a
        # multi-context container, else its first declared kind, else the
        # single context itself.
        #
        # @param ctx [Hash]
        # @return [Hash, nil]
        def primary_single_context(ctx)
          return ctx unless multi_context?(ctx)

          sub = ctx["user"]
          return sub if sub.is_a?(::Hash)

          ctx.each do |kind, value|
            next if kind == "kind"
            return value if value.is_a?(::Hash)
          end
          nil
        end

        # @param ctx [Hash]
        # @return [String] the primary context's key, or ""
        def primary_context_key(ctx)
          primary = primary_single_context(ctx)
          primary ? primary["key"].to_s : ""
        end

        # Resolve a dotted attribute path against a context.
        #
        #   "user.key"          the key of the user sub-context
        #   "organization.tier" the tier attribute of the organization one
        #   "userId"            legacy: the primary context's key
        #   any other bare name the primary context's attribute of that name
        #
        # @param ctx [Hash]
        # @param dotted_path [String, nil]
        # @return [Object, nil] nil when the path cannot be resolved
        def resolve_dotted_attribute(ctx, dotted_path)
          return nil if dotted_path.nil? || dotted_path.empty?

          dot_idx = dotted_path.index(".")
          if dot_idx && dot_idx > 0
            kind = dotted_path[0, dot_idx]
            attr = dotted_path[(dot_idx + 1)..]
            sub  = get_context_by_kind(ctx, kind)
            return nil unless sub

            return read_sub_attribute(sub, attr)
          end

          primary = primary_single_context(ctx)
          return nil unless primary

          return primary["key"] if dotted_path == "userId"

          read_sub_attribute(primary, dotted_path)
        end

        # Read one attribute off a sub-context, honouring the key and name
        # aliases and refusing SDK metadata.
        #
        # @param sub [Hash]
        # @param attribute [String]
        # @return [Object, nil]
        def read_sub_attribute(sub, attribute)
          return sub["key"]  if attribute == "key"
          return sub["name"] if attribute == "name"
          return nil         if RESERVED_KEYS.include?(attribute)

          sub[attribute]
        end

        # The kind and key pairs the decision log records. Attributes are
        # deliberately omitted: they may carry personal data.
        #
        # @param ctx [Hash]
        # @return [Array<Hash{Symbol=>String}>]
        def summary(ctx)
          if multi_context?(ctx)
            ctx.each_with_object([]) do |(kind, sub), acc|
              next if kind == "kind"
              next unless sub.is_a?(::Hash)

              acc << { kind: sub["kind"] || kind, key: sub["key"].to_s }
            end
          else
            [{ kind: ctx["kind"] || "user", key: ctx["key"].to_s }]
          end
        end
      end
    end
  end
end
