# frozen_string_literal: true

module Avsb
  module TestUtils
    # In-memory datafile loader for unit tests.
    # Accepts a plain Hash (already-parsed datafile JSON) and serves it
    # synchronously; no network call, no background thread.
    class InMemoryDatafileLoader
      attr_accessor :datafile

      def initialize(datafile = nil)
        @datafile  = datafile
        @callbacks = []
      end

      # Register a callback to be invoked when the datafile is replaced.
      def on_update(&block)
        @callbacks << block
      end

      # Replace the datafile and fire update callbacks.
      def update(new_datafile)
        @datafile = new_datafile
        @callbacks.each { |cb| cb.call(new_datafile) }
        nil
      end

      # Synchronous fetch: returns the stored datafile immediately.
      def fetch
        @datafile
      end
    end

    # Stub sticky bucket service that records all writes for assertion.
    class SpyStickyBucketService
      attr_reader :lookups, :saves

      def initialize(preset: {})
        @preset  = preset
        @lookups = []
        @saves   = []
      end

      def lookup(user_id, flag_key)
        @lookups << { user_id: user_id, flag_key: flag_key }
        @preset["#{user_id}:#{flag_key}"]
      end

      def save(user_id, flag_key, assignment)
        @saves << { user_id: user_id, flag_key: flag_key, assignment: assignment }
        nil
      end
    end
  end
end
