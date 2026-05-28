# frozen_string_literal: true

module Avsb
  module Core
    # BigSegmentStore interface (module) — implementations must respond to
    # #is_member?, #membership, and #healthy?
    #
    # Spec §2.9.
    module BigSegmentStore
      def is_member?(segment_key, context_key)
        raise NotImplementedError, "#{self.class}#is_member? is not implemented"
      end

      def membership(context_key)
        raise NotImplementedError, "#{self.class}#membership is not implemented"
      end

      def healthy?
        raise NotImplementedError, "#{self.class}#healthy? is not implemented"
      end
    end

    # In-memory BigSegmentStore implementation for testing.
    class InMemoryBigSegmentStore
      include BigSegmentStore

      # +data+ is a Hash of { segment_key => Set<context_key> }
      def initialize(data = {})
        @data = data
        @healthy = true
      end

      attr_writer :healthy

      def is_member?(segment_key, context_key)
        set = @data[segment_key]
        return false unless set

        set.include?(context_key)
      end

      def membership(context_key)
        result = {}
        @data.each do |segment_key, members|
          result[segment_key] = members.include?(context_key)
        end
        result
      end

      def healthy?
        @healthy
      end
    end
  end
end
