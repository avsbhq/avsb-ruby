# frozen_string_literal: true

# Optional dependency — guard-require so the gem loads without redis installed.
begin
  require "redis"
rescue LoadError
  # redis gem not installed; Avsb::Sticky::Redis will raise at instantiation.
end

require "json"

module Avsb
  module Sticky
    # Redis-backed sticky bucket service.
    #
    # Requires the `redis` gem (add to your Gemfile):
    #   gem "redis", "~> 5.0"
    #
    # Example usage in a Rails initializer:
    #   Avsb.configure do |c|
    #     c.sticky_bucket_service = Avsb::Sticky::Redis.new(
    #       Redis.new(url: ENV["REDIS_URL"]),
    #       ttl: 86_400 * 30
    #     )
    #   end
    class Redis
      KEY_PREFIX = "avsb:sticky:"

      # +client+ - a connected Redis client instance
      # +ttl+    - optional TTL in seconds (nil = no expiry)
      def initialize(client, ttl: nil)
        unless defined?(::Redis)
          raise LoadError, "Avsb::Sticky::Redis requires the redis gem. " \
                           "Add `gem 'redis', '~> 5.0'` to your Gemfile."
        end

        @client = client
        @ttl    = ttl
      end

      def lookup(user_id, flag_key)
        raw = @client.get(key_for(user_id, flag_key))
        return nil unless raw

        data = JSON.parse(raw, symbolize_names: true)
        data
      rescue ::Redis::BaseError, JSON::ParserError
        nil
      end

      def save(user_id, flag_key, assignment)
        k = key_for(user_id, flag_key)
        serialized = assignment.to_json
        if @ttl
          @client.setex(k, @ttl, serialized)
        else
          @client.set(k, serialized)
        end
        nil
      rescue ::Redis::BaseError
        nil
      end

      private

      def key_for(user_id, flag_key)
        "#{KEY_PREFIX}#{user_id}:#{flag_key}"
      end
    end
  end
end
