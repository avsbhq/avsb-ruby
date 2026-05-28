# frozen_string_literal: true

require_relative "hash"

module Avsb
  module Core
    # Holdout evaluator — spec §8.2.
    #
    # Walks the datafile's active holdouts; the first one that participates in
    # +flag_id+ and whose bucket lands inside its traffic-allocation window
    # classifies the context as held out. Bucketing is deterministic:
    #   murmurhash3(holdout_key + ':' + bucketing_key) % 10_000
    module Holdouts
      def self.evaluate_holdout(context, flag_id, datafile)
        holdouts = datafile["holdouts"]
        return { held_out: false } if holdouts.nil? || holdouts.empty?

        holdouts.each do |holdout|
          next unless (holdout["flagIds"] || []).include?(flag_id)
          next if holdout["trafficAllocation"].to_f <= 0

          bucket_key = resolve_bucket_key(context, holdout["hashAttribute"])
          hash       = Avsb::Core::Hash.murmurhash3("#{holdout["key"]}:#{bucket_key}") % 10_000
          threshold  = (holdout["trafficAllocation"].to_f * 10_000).floor
          next if hash >= threshold

          variation_id = (holdout["defaultVariationByFlag"] || {})[flag_id]
          result = { held_out: true, holdout: holdout }
          result[:variation_id] = variation_id if variation_id
          return result
        end

        { held_out: false }
      end

      def self.resolve_bucket_key(context, hash_attribute)
        require_relative "evaluate"
        val = Evaluator.resolve_dotted_attribute(context, hash_attribute || "userId")
        return "" if val.nil?

        val.to_s
      end
    end
  end
end
