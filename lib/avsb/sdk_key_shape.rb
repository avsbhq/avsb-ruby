# frozen_string_literal: true

module Avsb
  # SDK key shape validation at construction (spec section 1.2).
  #
  # Real keys are minted as +sdk_<environment_key>_<cuid2>+, where the
  # environment key matches /^[a-z][a-z0-9_]*$/ (it may itself contain
  # underscores, which is why this validates with one anchored pattern
  # instead of splitting on "_") and the cuid2 is 24 lowercase alphanumerics.
  #
  # A bad key used to be invisible: the CDN 404s, the fetch returns nothing,
  # and every flag silently serves its default. The common bad values are a
  # pasted dashboard URL, a truncated copy, a snippet key, or an API token in
  # the wrong field, and all four are recognisable on sight.
  #
  # This NEVER raises. A key we cannot recognise may still be valid (the mint
  # format can grow), so the SDK logs and proceeds with the value it was
  # given; the datafile fetch is the real arbiter. Wording is kept in step
  # with packages/avsb-browser/src/sdkKeyShape.ts on purpose: one message,
  # every SDK.
  module SdkKeyShape
    # Matches sdk_<envKey>_<id>; the trailing id segment carries no underscore.
    PATTERN = /\Asdk_[a-z][a-z0-9_]*_[a-z0-9]{8,}\z/

    # A real-shaped example, so the message is copy-comparable.
    EXAMPLE_KEY = "sdk_production_ttqm0eaj4vth1krcb2xn"

    class << self
      # @param sdk_key [String, nil]
      # @return [Boolean]
      def valid?(sdk_key)
        PATTERN.match?(sdk_key.to_s)
      end

      # The message to log for a key that does not look right.
      #
      # @param sdk_key [String, nil]
      # @return [String, nil] nil when the key looks valid
      def message_for(sdk_key)
        return nil if valid?(sdk_key)

        "AvsB SDK key \"#{describe(sdk_key)}\" does not look like an SDK key: " \
          "#{diagnose(sdk_key)}. Keys look like #{EXAMPLE_KEY} (sdk_<environment>_<id>). " \
          "Copy the key for the environment you want from app.avsb.cloud, then Settings, " \
          "then Environments. The SDK will keep going with the value you passed, so if the " \
          "datafile request 404s next, this is why."
      end

      # Redact all but the recognisable head of a key so a message can be
      # pasted into a bug report. The environment name is the useful half
      # ("you used the development key"); the cuid2 tail is not.
      #
      # @param sdk_key [String, nil]
      # @return [String]
      def describe(sdk_key)
        key = sdk_key.to_s
        return "(empty)" if key.empty?
        return key if key.length <= 12

        "#{key[0, 12]}...#{key[-4..]}"
      end

      private

      def diagnose(sdk_key)
        key     = sdk_key.to_s
        trimmed = key.strip

        return "no SDK key was passed at all" if trimmed.empty?

        if trimmed != key
          return "it has leading or trailing whitespace, which usually means a " \
                 "copy-paste picked up a line break"
        end
        if trimmed.match?(%r{\Ahttps?://}i)
          return "it looks like a URL, not a key. Copy the key itself, not the " \
                 "address of the page it is on"
        end
        if trimmed.start_with?("avsb_pat_", "avsb_svc_")
          return "it looks like an API token. API tokens talk to the management " \
                 "API; SDKs need the environment SDK key"
        end
        if trimmed.start_with?("sdk-", "pub_", "srv_")
          return "that key prefix has never existed in A vs B. There is one key " \
                 "format for SDKs"
        end
        return 'it does not start with "sdk_"' unless trimmed.start_with?("sdk_")
        if trimmed.split("_").length < 3
          return "it is missing the environment segment, so it may have been truncated"
        end

        "the id after the environment name is too short or has characters a " \
          "generated id never contains, so it may have been truncated or edited"
      end
    end
  end
end
