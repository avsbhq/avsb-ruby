# frozen_string_literal: true

module Avsb
  # Exponential backoff with jitter, honouring a server-supplied Retry-After.
  #
  # Port of packages/avsb-node/src/reconnectBackoff.ts, so every SDK retries
  # on the same curve: 1s, 2s, 4s, 8s, 16s, 32s, 60s (capped), with plus or
  # minus 20 percent of jitter.
  #
  # The jitter is the point. A fixed retry cadence means every SDK that
  # started together hits a struggling endpoint again in lockstep and stops
  # it recovering; drifting them apart is what breaks the herd.
  module Backoff
    BASE_DELAY = 1.0   # seconds
    MAX_DELAY  = 60.0
    MIN_DELAY  = 0.5
    JITTER     = 0.2

    # One rung of the curve.
    #
    #   attempt  #=> Integer  1 for the first retry
    #   delay    #=> Float    seconds to wait before that attempt
    State = Struct.new(:attempt, :delay)

    class << self
      # Next rung after +previous+ (nil for the first).
      #
      # @param previous [Avsb::Backoff::State, nil]
      # @param retry_after [Numeric, nil] seconds the server asked for
      # @param random [Object] anything responding to +rand+, injectable so a
      #   test can assert the curve without flakiness
      # @return [Avsb::Backoff::State]
      def next_backoff(previous, retry_after: nil, random: Kernel)
        attempt = (previous&.attempt || 0) + 1

        # An explicit Retry-After wins for this one attempt, and the attempt
        # counter still climbs so the next miss moves up the curve.
        if retry_after.is_a?(Numeric) && retry_after.positive?
          return State.new(attempt, retry_after.to_f)
        end

        base   = [MAX_DELAY, BASE_DELAY * (2**(attempt - 1))].min
        jitter = base * JITTER * ((random.rand * 2) - 1)
        State.new(attempt, [MIN_DELAY, base + jitter].max)
      end

      # Reset the curve after a success.
      # @return [nil]
      def reset
        nil
      end

      # Parse a Retry-After header value.
      #
      # Only the numeric-seconds form is supported, which is what the A vs B
      # workers emit. An HTTP-date returns nil and the caller falls back to
      # the exponential schedule.
      #
      # @param header_value [String, nil]
      # @return [Float, nil] seconds, or nil when the header is unusable
      def parse_retry_after(header_value)
        return nil if header_value.nil?

        trimmed = header_value.to_s.strip
        return nil if trimmed.empty?

        seconds = Float(trimmed, exception: false)
        return nil if seconds.nil? || seconds.negative?

        seconds
      end
    end
  end
end
