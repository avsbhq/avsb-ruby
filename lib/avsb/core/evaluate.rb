# frozen_string_literal: true

require_relative "hash"
require_relative "audience"
require_relative "holdouts"

module Avsb
  module Core
    # Flag evaluator: pure function over (flag_key, default_value, context, datafile).
    # Mirrors the logic in packages/avsb-core/src/evaluate.ts step-for-step.
    module Evaluator
      RESERVED_KEYS = %w[kind key name _meta].freeze

      # Evaluate +flag_key+ against +datafile+ for the given +context+.
      #
      # +context+       - plain Hash in EvalContext wire shape (SingleContext or MultiContext)
      # +datafile+       - plain Hash loaded from a FlagDatafile JSON
      # +default_value+  - caller-supplied fallback value
      # +reasons+        - optional Array to accumulate reason strings
      # +on_exposure+    - optional callable invoked with an exposure Hash on ab_test bucketing
      #
      # Returns a Hash with keys: :value, :variation_key, :source, :rule_id, :rule_type,
      #   :flag_key, :reasons
      def self.evaluate_flag(flag_key, default_value, context, datafile,
                             on_exposure: nil, reasons: nil)
        reasons ||= []

        # 1. FIND FLAG
        flag = (datafile["flags"] || []).find { |f| f["key"] == flag_key }
        unless flag
          reasons << "flag \"#{flag_key}\" not found in datafile"
          return build_result(default_value, nil, "not_found", nil, nil, flag_key, reasons)
        end

        # 2. CHECK ENABLED
        unless flag["enabled"]
          reasons << "flag \"#{flag_key}\" is disabled, returning default variation"
          default_var = get_variation(flag, flag["defaultVariationId"])
          val = default_var ? default_var["value"] : default_value
          key = default_var ? default_var["key"] : nil
          return build_result(val, key, "disabled", nil, nil, flag_key, reasons)
        end

        # 3. CHECK OVERRIDES
        primary_key = bucketing_key(context, "user") || primary_context_key(context)

        override = (flag["overrides"] || []).find { |o| o["userId"] == primary_key }
        if override
          reasons << "matched user override for userId=\"#{primary_key}\""
          ov = get_variation(flag, override["variationId"])
          val = ov ? ov["value"] : default_value
          key = ov ? ov["key"] : nil
          return build_result(val, key, "datafileOverride", nil, nil, flag_key, reasons)
        end

        # 4. HOLDOUT CHECK
        holdout_result = Holdouts.evaluate_holdout(context, flag["id"], datafile)
        if holdout_result[:held_out] && holdout_result[:holdout]
          h          = holdout_result[:holdout]
          target_vid = holdout_result[:variation_id] || flag["defaultVariationId"]
          holdout_var = get_variation(flag, target_vid)

          on_exposure&.call({
            "visitorId"    => primary_key,
            "experimentId" => h["id"],
            "variationId"  => target_vid,
            "eventName"    => "flag_holdout_exposure",
            "revenue"      => nil,
            "timestamp"    => (Time.now.to_f * 1000).to_i,
            "pageUrl"      => "",
            "properties"   => {
              "flagKey"    => flag_key,
              "flagId"     => flag["id"],
              "holdoutId"  => h["id"],
              "holdoutKey" => h["key"],
            },
          })

          hv_key = holdout_var ? holdout_var["key"] : target_vid
          reasons << "held out by holdout \"#{h["key"]}\", serving default variation \"#{hv_key}\""
          val = holdout_var ? holdout_var["value"] : default_value
          key = holdout_var ? holdout_var["key"] : nil
          return build_result(val, key, "holdout", h["id"], "holdout", flag_key, reasons)
        end

        # Build audience map
        audience_map = {}
        (datafile["audiences"] || []).each { |a| audience_map[a["id"]] = a }

        # 5. EVALUATE RULES (first match wins)
        (flag["rules"] || []).each do |rule|
          unless rule["enabled"]
            reasons << "rule \"#{rule["id"]}\" skipped (disabled)"
            next
          end

          hash_path  = rule["hashAttribute"] || "userId"
          hash_value = resolve_dotted_attribute(context, hash_path).to_s

          # a. CHECK AUDIENCE
          if rule["audienceIds"] && rule["audienceIds"].length > 0
            matched = rule["audienceIds"].any? do |aud_id|
              aud = audience_map[aud_id]
              next false unless aud

              Audience.evaluate_audience(aud, context)
            end
            unless matched
              reasons << "rule \"#{rule["id"]}\" skipped (audience not matched)"
              next
            end
          end

          # b. EVALUATE BY TYPE
          case rule["type"]
          when "targeted_delivery"
            next if (rule["variations"] || []).empty?

            target_var = get_variation(flag, rule["variations"][0]["variationId"])
            vk = target_var ? target_var["key"] : nil
            reasons << "rule \"#{rule["id"]}\" matched (targeted_delivery), serving variation \"#{vk}\""
            val = target_var ? target_var["value"] : default_value
            return build_result(val, vk, "rule", rule["id"], "targeted_delivery", flag_key, reasons)

          when "ab_test"
            alloc_hash = Avsb::Core::Hash.murmurhash3("#{hash_value}#{flag_key}__#{rule["id"]}") % 10_000
            traffic    = rule["trafficAllocation"]
            if traffic && alloc_hash >= (traffic * 10_000).to_i
              reasons << "rule \"#{rule["id"]}\" excluded by traffic allocation " \
                         "(hash #{alloc_hash} >= threshold #{(traffic * 10_000).to_i})"
              next
            end

            bucket      = Avsb::Core::Hash.murmurhash3("#{hash_value}#{flag_key}") % 10_000
            cumulative  = 0
            matched_var = nil
            matched_rv  = nil

            (rule["variations"] || []).each do |rv|
              cumulative += (rv["percentage"] * 10_000).to_i
              if bucket < cumulative
                matched_rv  = rv
                matched_var = get_variation(flag, rv["variationId"])
                break
              end
            end

            next unless matched_rv

            on_exposure&.call({
              "visitorId"    => hash_value,
              "experimentId" => rule["id"],
              "variationId"  => matched_rv["variationId"],
              "eventName"    => "flag_exposure",
              "revenue"      => nil,
              "timestamp"    => (Time.now.to_f * 1000).to_i,
              "pageUrl"      => "",
              "properties"   => { "flagKey" => flag_key, "flagId" => flag["id"] },
            })

            vk = matched_var ? matched_var["key"] : nil
            reasons << "rule \"#{rule["id"]}\" matched (ab_test), bucketed into variation " \
                       "\"#{vk}\" (hash #{bucket}/#{cumulative})"
            val = matched_var ? matched_var["value"] : default_value
            return build_result(val, vk, "rule", rule["id"], "ab_test", flag_key, reasons)
          end
        end

        # 6. DEFAULT
        reasons << "no rules matched, returning default variation"
        default_var = get_variation(flag, flag["defaultVariationId"])
        val = default_var ? default_var["value"] : default_value
        key = default_var ? default_var["key"] : nil
        build_result(val, key, "default", nil, nil, flag_key, reasons)
      end

      # Resolve a dotted attribute path (e.g. "user.key", "organization.tier")
      # against a context Hash.  Non-dotted paths fall back to primary context.
      def self.resolve_dotted_attribute(context, dotted_path)
        return nil if dotted_path.nil? || dotted_path.empty?

        dot_idx = dotted_path.index(".")
        if dot_idx && dot_idx > 0
          kind = dotted_path[0, dot_idx]
          attr = dotted_path[(dot_idx + 1)..]
          sub  = get_context_by_kind(context, kind)
          return nil unless sub

          return read_sub_attribute(sub, attr)
        end

        # Non-dotted — legacy lookup against primary context.
        primary = primary_single_context(context)
        return nil unless primary

        return primary["key"] if dotted_path == "userId"

        read_sub_attribute(primary, dotted_path)
      end

      def self.read_sub_attribute(sub, attr)
        return sub["key"]  if attr == "key"
        return sub["name"] if attr == "name"
        return nil         if RESERVED_KEYS.include?(attr)

        sub[attr]
      end

      def self.multi_context?(ctx)
        ctx.is_a?(Hash) && ctx["kind"] == "multi"
      end

      def self.get_context_by_kind(ctx, kind)
        if multi_context?(ctx)
          candidate = ctx[kind]
          return nil unless candidate.is_a?(Hash)
          return nil unless candidate["kind"] == kind

          candidate
        else
          ctx["kind"] == kind ? ctx : nil
        end
      end

      def self.bucketing_key(ctx, kind = "user")
        sub = get_context_by_kind(ctx, kind)
        sub ? sub["key"].to_s : ""
      end

      def self.primary_single_context(ctx)
        return ctx unless multi_context?(ctx)

        sub = ctx["user"]
        return sub if sub.is_a?(Hash)

        ctx.each do |k, v|
          next if k == "kind"
          return v if v.is_a?(Hash)
        end
        nil
      end

      def self.primary_context_key(ctx)
        pc = primary_single_context(ctx)
        pc ? pc["key"].to_s : ""
      end

      def self.get_variation(flag, variation_id)
        (flag["variations"] || []).find { |v| v["id"] == variation_id }
      end

      def self.build_result(value, variation_key, source, rule_id, rule_type, flag_key, reasons)
        {
          value:         value,
          variation_key: variation_key,
          source:        source,
          rule_id:       rule_id,
          rule_type:     rule_type,
          flag_key:      flag_key,
          reasons:       reasons.dup,
        }
      end
    end
  end
end
