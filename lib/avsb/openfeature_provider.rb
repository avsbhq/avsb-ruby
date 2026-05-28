# frozen_string_literal: true

# OpenFeature provider — optional integration.
# Requires the openfeature-sdk gem:
#   gem "openfeature-sdk"
#
# If the gem is not installed, this file loads without error but
# Avsb::OpenFeatureProvider will inherit from a plain Ruby class instead of
# OpenFeature::SDK::Provider::AbstractProvider.

begin
  require "open_feature/sdk"
  AVSB_OPENFEATURE_AVAILABLE = true
rescue LoadError
  AVSB_OPENFEATURE_AVAILABLE = false
end

module Avsb
  # OpenFeature provider backed by the A vs B SDK.
  #
  # Registration (Rails example):
  #   OpenFeature::SDK.configure do |config|
  #     config.set_provider(Avsb::OpenFeatureProvider.new(avsb_client))
  #   end
  class OpenFeatureProvider
    PROVIDER_NAME = "AvsB"

    def initialize(client)
      @client = client
    end

    def metadata
      { name: PROVIDER_NAME }
    end

    # Boolean resolution — maps to get_bool_flag.
    def resolve_boolean_value(flag_key, default_value, evaluation_context = nil)
      flag = @client.get_bool_flag(flag_key, default_value: default_value,
                                    context: context_from_of(evaluation_context))
      build_resolution(flag, default_value)
    end

    # String resolution — maps to get_string_flag.
    def resolve_string_value(flag_key, default_value, evaluation_context = nil)
      flag = @client.get_string_flag(flag_key, default_value: default_value,
                                      context: context_from_of(evaluation_context))
      build_resolution(flag, default_value)
    end

    # Number resolution — maps to get_number_flag.
    def resolve_number_value(flag_key, default_value, evaluation_context = nil)
      flag = @client.get_number_flag(flag_key, default_value: default_value,
                                      context: context_from_of(evaluation_context))
      build_resolution(flag, default_value)
    end

    # Object/JSON resolution — maps to get_json_flag.
    def resolve_object_value(flag_key, default_value, evaluation_context = nil)
      flag = @client.get_json_flag(flag_key, default_value: default_value,
                                   context: context_from_of(evaluation_context))
      build_resolution(flag, default_value)
    end

    private

    # Convert an OpenFeature EvaluationContext (Hash or object with #to_h) into
    # the plain Hash the A vs B SDK expects.
    def context_from_of(evaluation_context)
      return nil if evaluation_context.nil?

      h = evaluation_context.respond_to?(:to_h) ? evaluation_context.to_h : evaluation_context.dup
      # OpenFeature uses "targetingKey" as the primary key identifier.
      key  = h.delete("targetingKey") || h.delete(:targetingKey) || ""
      kind = h.delete("kind") || h.delete(:kind) || "user"
      h.transform_keys!(&:to_s)
      h.merge("kind" => kind.to_s, "key" => key.to_s)
    end

    def build_resolution(flag, default_value)
      {
        value:         flag.value,
        variant:       flag.variation_key,
        reason:        map_reason(flag.source),
        error_code:    nil,
        error_message: nil,
      }
    rescue StandardError => e
      {
        value:         default_value,
        variant:       nil,
        reason:        "ERROR",
        error_code:    "GENERAL",
        error_message: e.message,
      }
    end

    # Map Avsb evaluation source strings to OpenFeature reason strings.
    def map_reason(source)
      case source
      when "rule"              then "TARGETING_MATCH"
      when "override"          then "STATIC"
      when "datafileOverride"  then "STATIC"
      when "runtimeOverride"   then "STATIC"
      when "sticky"            then "CACHED"
      when "holdout"           then "TARGETING_MATCH"
      when "default"           then "DEFAULT"
      when "not_found"         then "DEFAULT"
      when "disabled"          then "DISABLED"
      else                          "UNKNOWN"
      end
    end
  end
end
