# frozen_string_literal: true

module Avsb
  module Sticky
    # In-memory sticky bucket service.
    # Thread-safe via Mutex for multi-threaded web servers.
    class InMemory
      def initialize
        @store = {}
        @mutex = Mutex.new
      end

      # Synchronous lookup (hot-path safe).
      # Returns a Hash with :variation_id, :rule_id, :rule_type, :assigned_at
      # or nil when no assignment exists.
      def lookup(user_id, flag_key)
        @mutex.synchronize { @store["#{user_id}:#{flag_key}"] }
      end

      # Persist an assignment. Fire-and-forget.
      def save(user_id, flag_key, assignment)
        @mutex.synchronize { @store["#{user_id}:#{flag_key}"] = assignment }
        nil
      end

      def size
        @mutex.synchronize { @store.size }
      end

      def clear
        @mutex.synchronize { @store.clear }
      end
    end
  end
end
