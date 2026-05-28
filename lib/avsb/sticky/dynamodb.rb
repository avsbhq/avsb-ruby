# frozen_string_literal: true

# Optional dependency — guard-require so the gem loads without aws-sdk-dynamodb.
begin
  require "aws-sdk-dynamodb"
rescue LoadError
  # aws-sdk-dynamodb not installed; Avsb::Sticky::DynamoDB will raise at instantiation.
end

require "json"

module Avsb
  module Sticky
    # DynamoDB-backed sticky bucket service.
    #
    # Requires the `aws-sdk-dynamodb` gem (add to your Gemfile):
    #   gem "aws-sdk-dynamodb", "~> 1"
    #
    # Table schema:
    #   Partition key: pk (String) — "avsb#<user_id>#<flag_key>"
    #   Attribute:     assignment (Map) — the serialised assignment hash
    #   Optional TTL:  ttl (Number) — epoch seconds for DynamoDB TTL
    #
    # Example usage in a Rails initializer:
    #   Avsb.configure do |c|
    #     c.sticky_bucket_service = Avsb::Sticky::DynamoDB.new(
    #       Aws::DynamoDB::Client.new(region: "us-east-1"),
    #       table_name: "avsb_sticky",
    #       ttl_days: 30
    #     )
    #   end
    class DynamoDB
      PK_PREFIX = "avsb"

      def initialize(client, table_name:, ttl_days: nil)
        unless defined?(Aws::DynamoDB::Client)
          raise LoadError, "Avsb::Sticky::DynamoDB requires the aws-sdk-dynamodb gem. " \
                           "Add `gem 'aws-sdk-dynamodb', '~> 1'` to your Gemfile."
        end

        @client     = client
        @table_name = table_name
        @ttl_days   = ttl_days
      end

      def lookup(user_id, flag_key)
        resp = @client.get_item(
          table_name: @table_name,
          key:        { "pk" => pk_for(user_id, flag_key) },
        )
        item = resp.item
        return nil unless item && item["assignment"]

        deep_symbolize(item["assignment"])
      rescue Aws::DynamoDB::Errors::ServiceError
        nil
      end

      def save(user_id, flag_key, assignment)
        item = { "pk" => pk_for(user_id, flag_key), "assignment" => deep_stringify(assignment) }
        item["ttl"] = (Time.now.to_i + @ttl_days * 86_400).to_s if @ttl_days
        @client.put_item(table_name: @table_name, item: item)
        nil
      rescue Aws::DynamoDB::Errors::ServiceError
        nil
      end

      private

      def pk_for(user_id, flag_key)
        "#{PK_PREFIX}##{user_id}##{flag_key}"
      end

      def deep_symbolize(obj)
        case obj
        when Hash  then obj.transform_keys(&:to_sym).transform_values { |v| deep_symbolize(v) }
        when Array then obj.map { |v| deep_symbolize(v) }
        else            obj
        end
      end

      def deep_stringify(obj)
        case obj
        when Hash   then obj.transform_keys(&:to_s).transform_values { |v| deep_stringify(v) }
        when Array  then obj.map { |v| deep_stringify(v) }
        when Symbol then obj.to_s
        else             obj
        end
      end
    end
  end
end
