# frozen_string_literal: true

require "json"

require_relative "endpoints"
require_relative "http"
require_relative "version"

module Avsb
  # SDK liveness.
  #
  # The dashboard's Environments page shows Connected, Stale, or Not connected
  # from these, so an SDK that never sends one looks offline no matter how well
  # it works.
  #
  # The endpoint is server controlled: it comes from the datafile's
  # +heartbeatEndpoint+ and there is no default. A proxied deployment publishes
  # its own origin, and a heartbeat posted to the wrong host would report
  # liveness nowhere while looking healthy.
  #
  # Sends are throttled to one per +interval+ per process rather than one per
  # datafile refresh. A fleet polling every 60 seconds would otherwise pay a
  # request a minute per process to report something that changes hourly.
  class Heartbeat
    # The package identifier, exactly as published. The dashboard groups
    # environments by this string.
    SDK_TYPE = "avsb-ruby"

    DEFAULT_INTERVAL = 900 # seconds
    REQUEST_TIMEOUT  = 5   # seconds

    # @param sdk_key [String]
    # @param logger [Object] responds to debug/info/warn/error
    # @param interval [Numeric] minimum seconds between sends
    def initialize(sdk_key:, logger:, interval: DEFAULT_INTERVAL)
      @sdk_key  = sdk_key
      @logger   = logger
      @interval = interval
      @last_sent_at = nil
    end

    # Send one heartbeat if the datafile names an endpoint and enough time has
    # passed since the last.
    #
    # A failed heartbeat is logged at debug and never retried: liveness is a
    # nicety, and the next refresh will try again.
    #
    # @param datafile [Hash, nil]
    # @return [Boolean] true when a request was made and accepted
    def send_if_due(datafile)
      endpoint = Avsb::Endpoints.resolve_heartbeat_endpoint(
        datafile && datafile["heartbeatEndpoint"]
      )
      return false unless endpoint
      return false unless due?

      @last_sent_at = monotonic_now
      response = Avsb::Http.post_json(endpoint, body, timeout: REQUEST_TIMEOUT)
      return true if response.ok?

      @logger.debug("avsb heartbeat to #{endpoint} returned " \
                    "#{response.error || "HTTP #{response.status}"}")
      false
    end

    private

    def due?
      return true if @last_sent_at.nil?

      (monotonic_now - @last_sent_at) >= @interval
    end

    # The locked wire shape: three fields, no more.
    def body
      JSON.generate({
        "sdkKey"     => @sdk_key,
        "sdkType"    => SDK_TYPE,
        "sdkVersion" => Avsb::VERSION,
      })
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
