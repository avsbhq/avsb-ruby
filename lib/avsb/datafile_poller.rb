# frozen_string_literal: true

require_relative "endpoints"
require_relative "backoff"
require_relative "http"

module Avsb
  # Fetches the datafile and keeps it fresh.
  #
  # Split out of Avsb::Server so the refresh loop can be read, and tested, on
  # its own. Three things here are deliberate:
  #
  #   * The URL comes from Avsb::Endpoints. This SDK used to build
  #     "https://cdn.avsb.cloud/v1/datafiles/<key>.json" by hand, which 404s:
  #     no Ruby process could ever initialise against production.
  #   * Stopping is cooperative. The old close killed the thread, which can
  #     abort mid-request and leave a half-read socket behind.
  #   * Failures back off with jitter and keep trying. A poll loop that gives
  #     up after the first error leaves the process serving defaults until
  #     someone restarts it.
  class DatafilePoller
    DEFAULT_POLLING_INTERVAL = 60 # seconds
    FETCH_TIMEOUT            = 10 # seconds

    # @param sdk_key [String]
    # @param logger [Object] responds to debug/info/warn/error
    # @param cdn_host [String] override for a proxy or local dev
    # @param polling_interval [Numeric] seconds between refreshes
    # @param on_update [Proc] called with the parsed datafile Hash
    # @param on_error [Proc] called with a StandardError on every failure
    def initialize(sdk_key:, logger:, cdn_host: Avsb::Endpoints::DEFAULT_CDN_HOST,
                   polling_interval: DEFAULT_POLLING_INTERVAL,
                   on_update:, on_error:)
      @sdk_key  = sdk_key
      @logger   = logger
      @url      = Avsb::Endpoints.datafile_url(sdk_key, cdn_host: cdn_host)
      @interval = polling_interval
      @on_update = on_update
      @on_error  = on_error

      @thread     = nil
      @running    = false
      @stop_mutex = Mutex.new
      @stop_cv    = ConditionVariable.new
    end

    # @return [String] the exact URL this poller reads
    attr_reader :url

    # Fetch once, synchronously.
    #
    # @return [Hash] +{datafile: Hash}+ on success, +{error: StandardError}+
    #   on failure. Never raises: the caller decides what a failure means.
    def fetch_once
      response = Avsb::Http.get(@url, timeout: FETCH_TIMEOUT)

      unless response.ok?
        return { error: RuntimeError.new(failure_message(response)) }
      end

      parsed = response.json
      unless parsed.is_a?(::Hash)
        return { error: RuntimeError.new(
          "AvsB datafile at #{@url} was not JSON. Got #{response.body.to_s[0, 120].inspect}. " \
          "A proxy or captive portal may be rewriting the response."
        ) }
      end

      { datafile: parsed }
    end

    # Start the refresh loop.
    # @return [self]
    def start
      return self if @thread

      @running = true
      @thread  = Thread.new { run_loop }
      @thread.abort_on_exception = false
      self
    end

    # Stop the refresh loop and wait for the thread to finish its current
    # iteration.
    #
    # @param timeout [Numeric] seconds to wait for the thread to land
    # @return [void]
    def close(timeout: FETCH_TIMEOUT)
      @running = false
      @stop_mutex.synchronize { @stop_cv.broadcast }
      @thread&.join(timeout)
      @thread = nil
    end

    # @return [Boolean]
    def running?
      @running && !@thread.nil? && @thread.alive?
    end

    private

    def run_loop
      backoff = Avsb::Backoff.reset

      while @running
        delay = backoff ? backoff.delay : @interval
        @stop_mutex.synchronize { @stop_cv.wait(@stop_mutex, delay) }
        break unless @running

        result = fetch_once
        if result[:datafile]
          backoff = Avsb::Backoff.reset
          begin
            @on_update.call(result[:datafile])
          rescue StandardError => e
            @logger.error("avsb datafile update handler raised: #{e.class}: #{e.message}")
          end
        else
          backoff = Avsb::Backoff.next_backoff(backoff)
          @logger.warn("avsb datafile refresh failed, retrying in " \
                       "#{backoff.delay.round(1)}s: #{result[:error].message}")
          @on_error.call(result[:error])
        end
      end
    end

    # Loud failure: what failed, the exact value involved, and how to
    # reproduce it without the SDK in the way.
    def failure_message(response)
      if response.status.zero?
        return "AvsB datafile fetch to #{@url} failed before it got a response " \
               "(#{response.error}). Check outbound network access and any proxy or " \
               "firewall rules for cdn.avsb.cloud. Reproduce with: curl -i #{@url}"
      end

      hint = case response.status
             when 404
               "A 404 means the CDN has no datafile for this SDK key. Either the key is " \
               "wrong or the environment has never been published: open the A vs B " \
               "dashboard, then Settings, then Environments, and publish it."
             when 403
               "A 403 usually means a proxy in front of the CDN is blocking the request."
             else
               "Status #{response.status} came from the CDN edge, not the SDK."
             end

      "AvsB datafile fetch to #{@url} returned HTTP #{response.status}. #{hint} " \
        "Reproduce with: curl -i #{@url}"
    end
  end
end
