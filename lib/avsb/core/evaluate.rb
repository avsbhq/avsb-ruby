# frozen_string_literal: true

require_relative "hash"
require_relative "audience"
require_relative "holdouts"
require_relative "js_value"
require_relative "context_resolver"
require_relative "bandit_dispatch"

module Avsb
  module Core
    # Flag evaluator: pure function over (flag_key, default_value, context, datafile).
    # Mirrors packages/avsb-core/src/evaluate.ts step for step, and every
    # step is locked by the conformance corpus, including the exact reason
    # strings in their exact order.
    #
    # Context reading (kinds, keys, dotted paths) lives in
    # Avsb::Core::ContextResolver, which audience matching and holdout
    # bucketing share.
    module Evaluator
      MAX_BUCKET = 10_000

      # Evaluate +flag_key+ against +datafile+ for the given +context+.
      #
      # @param flag_key [String] the flag key to evaluate
      # @param default_value [Object] caller-supplied fallback value
      # @param context [Hash] plain Hash in EvalContext wire shape
      #   (SingleContext or MultiContext)
      # @param datafile [Hash] plain Hash parsed from a FlagDatafile JSON
      # @param on_exposure [Proc, nil] called with an exposure Hash when an
      #   ab_test, bandit, or holdout decision is served
      # @param reasons [Array<String>, nil] accumulator for the decision trail
      # @param bandit_model_store [Object, nil] object responding to
      #   +get_model(key)+ / +update_model(key, model)+. When nil, bandit
      #   rules run their cold-start policy instead of being skipped.
      # @return [Hash{Symbol=>Object}] keys +:value+, +:variation_key+,
      #   +:source+, +:rule_id+, +:rule_type+, +:flag_key+, +:reasons+
      def self.evaluate_flag(flag_key, default_value, context, datafile,
                             on_exposure: nil, reasons: nil, bandit_model_store: nil)
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
        #
        # Overrides match on the primary context's key (legacy "userId").
        # The `user` kind wins; when there is no user sub-context the first
        # declared kind is the primary. The empty-string check is deliberate:
        # in JavaScript "" is falsy and the reference falls through to the
        # primary context, while in Ruby "" is truthy and would stop here.
        primary_key = ContextResolver.bucketing_key(context, "user")
        primary_key = ContextResolver.primary_context_key(context) if primary_key.empty?

        override = (flag["overrides"] || []).find { |o| o["userId"] == primary_key }
        if override
          reasons << "matched user override for userId=\"#{primary_key}\""
          ov = get_variation(flag, override["variationId"])
          val = ov ? ov["value"] : default_value
          key = ov ? ov["key"] : nil
          return build_result(val, key, "datafileOverride", nil, nil, flag_key, reasons)
        end

        # 4. HOLDOUT CHECK
        #
        # Fires between overrides and the rules loop so datafile overrides
        # still win (explicit operator intent), while every regular rule
        # evaluation honours the holdout.
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
            "timestamp"    => now_ms,
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
        currency_exponent = datafile["currencyExponent"]

        # 5. EVALUATE RULES (first match wins)
        (flag["rules"] || []).each do |rule|
          unless rule["enabled"]
            reasons << "rule \"#{rule["id"]}\" skipped (disabled)"
            next
          end

          hash_path  = rule["hashAttribute"] || "userId"
          resolved   = ContextResolver.resolve_dotted_attribute(context, hash_path)
          hash_value = resolved.nil? ? "" : resolved.to_s

          # a. CHECK AUDIENCE
          if rule["audienceIds"] && !rule["audienceIds"].empty?
            matched = rule["audienceIds"].any? do |aud_id|
              aud = audience_map[aud_id]
              next false unless aud

              Audience.evaluate_audience(aud, context, currency_exponent: currency_exponent)
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

            # A targeted delivery rule below 100 percent is a ROLLOUT: serve
            # the variation to that share of the audience and let everyone
            # else fall through to the next rule, exactly as an ab_test rule's
            # allocation does (N1-1). The gate sits after the empty-variations
            # skip, so a rule with nothing to serve stays a silent skip.
            td_exclusion = allocation_exclusion(rule, flag_key, hash_value)
            if td_exclusion
              reasons << td_exclusion
              next
            end

            target_var = get_variation(flag, rule["variations"][0]["variationId"])
            vk = target_var ? target_var["key"] : nil
            reasons << "rule \"#{rule["id"]}\" matched (targeted_delivery), " \
                       "serving variation \"#{key_text(target_var)}\""
            val = target_var ? target_var["value"] : default_value
            return build_result(val, vk, "rule", rule["id"], "targeted_delivery", flag_key, reasons)

          when "ab_test"
            result = evaluate_ab_test(
              flag, rule, flag_key, default_value, hash_value, reasons, on_exposure
            )
            next unless result

            return result

          when "bandit"
            result = evaluate_bandit_rule(
              flag, rule, flag_key, hash_value, context, datafile, reasons,
              on_exposure, bandit_model_store
            )
            next unless result

            return result

          else
            # Unknown rule type on the wire: name it rather than dropping it.
            reasons << "rule \"#{rule["id"]}\" skipped (unsupported rule type \"#{rule["type"]}\")"
            next
          end
        end

        # 6. DEFAULT
        reasons << "no rules matched, returning default variation"
        default_var = get_variation(flag, flag["defaultVariationId"])
        val = default_var ? default_var["value"] : default_value
        key = default_var ? default_var["key"] : nil
        build_result(val, key, "default", nil, nil, flag_key, reasons)
      end

      # The traffic-allocation gate shared by ab_test and targeted_delivery
      # rules. Mirrors allocationExclusion in packages/avsb-core/src/evaluate.ts.
      # Returns the exclusion reason when the context falls outside the rule's
      # allocation, nil when it is inside or the rule declares no gate.
      #
      # One hash input serves both rule types (hash value, flag key, "__",
      # rule id), so a visitor's rollout membership is the same in every SDK
      # and does not move when a rule changes type.
      #
      # The threshold is a FLOAT comparison against the raw product, never a
      # truncated or rounded integer. A 0.12345 rollout puts the threshold at
      # 1234.5: bucket 1234 is inside it, while a port that truncates to 1234
      # excludes that context and diverges by one bucket in ten thousand. The
      # boundary fixtures lock both the fractional and the integer forms.
      #
      # nil means no gate, and so does a field missing from an old datafile.
      def self.allocation_exclusion(rule, flag_key, hash_value)
        traffic = rule["trafficAllocation"]
        return nil if traffic.nil?

        alloc_hash = Avsb::Core::Hash.murmurhash3("#{hash_value}#{flag_key}__#{rule["id"]}") % MAX_BUCKET
        threshold  = traffic.to_f * MAX_BUCKET
        return nil unless alloc_hash >= threshold

        "rule \"#{rule["id"]}\" excluded by traffic allocation " \
          "(hash #{alloc_hash} >= threshold #{JsValue.number_to_s(threshold)})"
      end

      # ab_test branch. Returns a result Hash on a match, nil to continue to
      # the next rule.
      def self.evaluate_ab_test(flag, rule, flag_key, default_value, hash_value,
                                reasons, on_exposure)
        # Traffic allocation, shared with targeted_delivery rules.
        exclusion = allocation_exclusion(rule, flag_key, hash_value)
        if exclusion
          reasons << exclusion
          return nil
        end

        bucket     = Avsb::Core::Hash.murmurhash3("#{hash_value}#{flag_key}") % MAX_BUCKET
        cumulative = 0.0

        (rule["variations"] || []).each do |rv|
          # Cumulative boundaries stay in floating point for the same reason
          # the threshold does: 0.12345 accumulates to 1234.5, and bucket
          # 1234 belongs to the first variation.
          cumulative += rv["percentage"].to_f * MAX_BUCKET
          next unless bucket < cumulative

          exp_var = get_variation(flag, rv["variationId"])

          if on_exposure && exp_var
            on_exposure.call({
              "visitorId"    => hash_value,
              "experimentId" => rule["id"],
              "variationId"  => rv["variationId"],
              "eventName"    => "flag_exposure",
              "revenue"      => nil,
              "timestamp"    => now_ms,
              "pageUrl"      => "",
              "properties"   => { "flagKey" => flag_key, "flagId" => flag["id"] },
            })
          end

          reasons << "rule \"#{rule["id"]}\" matched (ab_test), bucketed into variation " \
                     "\"#{key_text(exp_var)}\" (hash #{bucket}/#{JsValue.number_to_s(cumulative)})"
          val = exp_var ? exp_var["value"] : default_value
          vk  = exp_var ? exp_var["key"] : nil
          return build_result(val, vk, "rule", rule["id"], "ab_test", flag_key, reasons)
        end

        nil
      end

      # bandit branch. Returns a result Hash on a match, nil to continue to
      # the next rule. Every exit appends a reason: a bandit rule must never
      # disappear from the decision trail.
      def self.evaluate_bandit_rule(flag, rule, flag_key, hash_value, context, datafile,
                                    reasons, on_exposure, bandit_model_store)
        bandit = BanditDispatch.resolve_rule_bandit(rule, datafile)
        unless bandit
          reasons << if rule["banditId"]
                       "rule \"#{rule["id"]}\" skipped (banditId \"#{rule["banditId"]}\" " \
                       "is not in datafile.bandits)"
                     else
                       "rule \"#{rule["id"]}\" skipped (bandit rule carries no bandit config)"
                     end
          return nil
        end

        actions = bandit[:config]["actions"] || []
        if actions.empty?
          reasons << "rule \"#{rule["id"]}\" skipped (bandit \"#{bandit[:key]}\" declares no actions)"
          return nil
        end

        store    = BanditDispatch.store_for(bandit[:config], bandit_model_store)
        decision = Bandits.evaluate_bandit(bandit[:key], bandit[:config], context, store)
        unless decision
          reasons << "rule \"#{rule["id"]}\" skipped (bandit \"#{bandit[:key]}\" " \
                     "has no model in the supplied store)"
          return nil
        end

        action     = decision[:action]
        bandit_var = get_variation(flag, action["variationId"])
        unless bandit_var
          reasons << "rule \"#{rule["id"]}\" skipped (bandit \"#{bandit[:key]}\" " \
                     "action \"#{action["id"]}\" targets unknown variation " \
                     "\"#{action["variationId"]}\")"
          return nil
        end

        on_exposure&.call({
          "visitorId"    => hash_value,
          "experimentId" => rule["id"],
          "variationId"  => action["variationId"],
          "eventName"    => "flag_exposure",
          "revenue"      => nil,
          "timestamp"    => now_ms,
          "pageUrl"      => "",
          "properties"   => {
            "flagKey"   => flag_key,
            "flagId"    => flag["id"],
            "banditKey" => bandit[:key],
            "actionId"  => action["id"],
          },
        })

        reasons << "rule \"#{rule["id"]}\" matched (bandit \"#{bandit[:key]}\"), " \
                   "served action \"#{action["id"]}\" into variation \"#{bandit_var["key"]}\""
        build_result(bandit_var["value"], bandit_var["key"], "bandit", rule["id"], "bandit",
                     flag_key, reasons)
      end

      # Resolve a dotted attribute path against a context.
      #
      # Kept on the evaluator because the reference exports it from evaluate.ts
      # for exactly this reason: the bucketing input is part of the evaluation
      # contract, not an implementation detail. The rules live in
      # Avsb::Core::ContextResolver, which audience matching and holdout
      # bucketing share.
      #
      # @param context [Hash]
      # @param dotted_path [String, nil]
      # @return [Object, nil] the resolved value, or nil when unresolvable
      def self.resolve_dotted_attribute(context, dotted_path)
        ContextResolver.resolve_dotted_attribute(context, dotted_path)
      end

      def self.get_variation(flag, variation_id)
        (flag["variations"] || []).find { |v| v["id"] == variation_id }
      end

      # Reason strings print the variation key the reference prints. When the
      # rule points at a variation the flag no longer carries, the reference
      # interpolates a missing value and JavaScript renders the word
      # "undefined"; matching that keeps the recorded decision trail
      # byte-identical across languages.
      def self.key_text(variation)
        variation ? variation["key"] : "undefined"
      end

      def self.now_ms
        (Time.now.to_f * 1000).to_i
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
