# frozen_string_literal: true

require "json"
require "securerandom"

require_relative "endpoints"
require_relative "backoff"
require_relative "http"

module Avsb
  # Batched event tracker.
  #
  # Mirrors the semantics of packages/avsb-node/src/serverTracker.ts, because
  # exposures and conversions from a Ruby process must land in the same
  # columns, with the same field names, as the ones from a Node process:
  #
  #   * Bounded queues. A queue that grows without limit turns a broken
  #     ingest endpoint into a memory leak, so the newest events win and the
  #     drop is logged rather than silent.
  #   * eventId stamped once, at enqueue. A retried batch carries the same
  #     ids, so ingestion can deduplicate instead of double-counting.
  #   * Retry with jittered exponential backoff, honouring Retry-After.
  #   * Flush on close, so a shutting-down process does not throw away the
  #     conversions it just recorded.
  #
  # The body field names are frozen vocabulary
  # (packages/avsb-conformance/fixtures/wire/manifest.json). A renamed field
  # is not a rejected request: it is data that looks delivered and is gone.
  class Tracker
    DEFAULT_FLUSH_INTERVAL = 5     # seconds
    DEFAULT_BATCH_SIZE     = 20
    DEFAULT_MAX_QUEUE_SIZE = 1_000
    DEFAULT_RETRY_ATTEMPTS = 3
    REQUEST_TIMEOUT        = 10    # seconds

    # @param sdk_key [String] carried in every body envelope as +sdkKey+
    # @param collect_endpoint [String] ingest origin, from the datafile's
    #   +collectEndpoint+
    # @param logger [Object] responds to debug/info/warn/error
    # @param flush_interval [Numeric] seconds between automatic flushes
    # @param batch_size [Integer] events per request, and the queue depth that
    #   triggers an immediate flush
    # @param max_queue_size [Integer] hard cap per queue
    # @param retry_attempts [Integer] retries after the first attempt
    # @param auto_flush [Boolean] start the background flush thread. Pass
    #   false when the caller flushes explicitly, for example in a test or a
    #   one-shot script.
    def initialize(sdk_key:, collect_endpoint:, logger:,
                   flush_interval: DEFAULT_FLUSH_INTERVAL,
                   batch_size: DEFAULT_BATCH_SIZE,
                   max_queue_size: DEFAULT_MAX_QUEUE_SIZE,
                   retry_attempts: DEFAULT_RETRY_ATTEMPTS,
                   auto_flush: true)
      @sdk_key         = sdk_key
      @collect_endpoint = collect_endpoint
      @logger          = logger
      @flush_interval  = flush_interval
      @batch_size      = batch_size
      @max_queue_size  = max_queue_size
      @retry_attempts  = retry_attempts

      @exposures = []
      @metrics   = []
      @mutex     = Mutex.new
      @closed    = false

      @stop_mutex = Mutex.new
      @stop_cv    = ConditionVariable.new
      @thread     = auto_flush ? start_flush_thread : nil
    end

    # Point the tracker at a new ingest origin, after a datafile refresh
    # moved it.
    # @param collect_endpoint [String]
    # @return [void]
    def update_collect_endpoint(collect_endpoint)
      @mutex.synchronize { @collect_endpoint = collect_endpoint }
    end

    # Queue an exposure event (an ab_test, bandit, or holdout decision).
    #
    # @param event [Hash{String=>Object}] wire-shaped exposure without eventId
    # @return [void]
    def queue(event)
      return if @closed

      flush_now = false
      @mutex.synchronize do
        @exposures << stamp(event)
        trim(@exposures, "Event")
        flush_now = @exposures.length >= @batch_size
      end
      request_flush if flush_now
    end

    # Queue a metric event (a conversion).
    #
    # @param event [Hash{String=>Object}] wire-shaped metric without eventId
    # @return [void]
    def queue_metric(event)
      return if @closed

      flush_now = false
      @mutex.synchronize do
        @metrics << stamp(event)
        trim(@metrics, "Metric")
        flush_now = @metrics.length >= @batch_size
      end
      request_flush if flush_now
    end

    # Send one order immediately.
    #
    # Orders are not batched: a purchase is the event a customer least wants
    # buffered in a process that might exit.
    #
    # @param visitor_id [String] the bucketing key the exposure used
    # @param order [Hash{String=>Object}] +orderId+ and +total+ required
    # @return [Boolean] true when ingest accepted it
    def track_purchase(visitor_id, order)
      return false if @closed

      payload = order.merge(
        "eventId"   => SecureRandom.uuid,
        "visitorId" => visitor_id.to_s,
        "timestamp" => order["timestamp"] || now_ms,
        "pageUrl"   => order["pageUrl"] || "",
      )
      send_with_retry(collect_url("orders"), { "sdkKey" => @sdk_key, "orders" => [payload] }, 1)
    end

    # Send everything queued, in batches.
    # @return [void]
    def flush
      exposures = nil
      metrics   = nil
      @mutex.synchronize do
        return if @exposures.empty? && @metrics.empty?

        exposures = @exposures
        metrics   = @metrics
        @exposures = []
        @metrics   = []
      end

      exposures.each_slice(@batch_size) do |chunk|
        send_with_retry(collect_url("batch"), { "sdkKey" => @sdk_key, "events" => chunk }, chunk.length)
      end
      metrics.each_slice(@batch_size) do |chunk|
        send_with_retry(collect_url("metric_batch"),
                        { "sdkKey" => @sdk_key, "metricEvents" => chunk }, chunk.length)
      end
    end

    # Stop the flush thread and send what is left.
    #
    # Signals the thread and joins it rather than killing it: a killed thread
    # can die mid-request and lose the batch it was sending.
    # @return [void]
    def close
      return if @closed

      @closed = true
      @stop_mutex.synchronize { @stop_cv.broadcast }
      @thread&.join(REQUEST_TIMEOUT)
      @thread = nil
      flush
    end

    # @return [Integer] events waiting to be sent, both queues
    def pending_count
      @mutex.synchronize { @exposures.length + @metrics.length }
    end

    private

    # A full batch wakes the flush thread instead of sending on the caller's
    # thread. Sending inline would put the retry backoff (up to seconds)
    # inside a web request that happened to be the one that filled the batch.
    # With no thread, the caller owns flushing and gets it synchronously.
    def request_flush
      if @thread
        @stop_mutex.synchronize { @stop_cv.broadcast }
      else
        flush
      end
    end

    def start_flush_thread
      thread = Thread.new do
        until @closed
          @stop_mutex.synchronize { @stop_cv.wait(@stop_mutex, @flush_interval) }
          break if @closed

          begin
            flush
          rescue StandardError => e
            @logger.error("avsb tracker flush failed: #{e.class}: #{e.message}")
          end
        end
      end
      thread.abort_on_exception = false
      thread
    end

    def stamp(event)
      copy = event.dup
      copy["eventId"] ||= SecureRandom.uuid
      copy
    end

    # Keep the newest events. Called with the mutex held.
    def trim(queue, label)
      return if queue.length <= @max_queue_size

      dropped = queue.length - @max_queue_size
      queue.slice!(0, dropped)
      @logger.warn(
        "#{label} queue full (#{@max_queue_size}), dropped #{dropped} oldest event(s). " \
        "Ingest may be unreachable, or events are being produced faster than " \
        "flush_interval can send them."
      )
    end

    # Called only outside the queue mutex, so taking it here is safe.
    def collect_url(kind)
      endpoint = @mutex.synchronize { @collect_endpoint }
      Avsb::Endpoints.collect_url(kind, collect_endpoint: endpoint)
    end

    # One request, retried on the shared backoff curve. The body is
    # serialised once so every attempt carries identical eventIds.
    def send_with_retry(url, body, count)
      payload = JSON.generate(body)
      state   = Avsb::Backoff.reset
      pending_retry_after = nil

      (0..@retry_attempts).each do |attempt|
        response = Avsb::Http.post_json(url, payload, timeout: REQUEST_TIMEOUT)
        if response.ok?
          @logger.debug("avsb flushed #{count} event(s) to #{url}")
          return true
        end

        pending_retry_after = Avsb::Backoff.parse_retry_after(response.retry_after)
        detail = response.error || "HTTP #{response.status}"

        if attempt < @retry_attempts
          state = Avsb::Backoff.next_backoff(state, retry_after: pending_retry_after)
          sleep(state.delay)
        else
          @logger.error(
            "avsb failed to send #{count} event(s) to #{url} after #{@retry_attempts} " \
            "retries (#{detail}). Reproduce with: " \
            "curl -i -X POST #{url} -H 'Content-Type: application/json' -d '#{payload}'"
          )
        end
      end

      false
    end

    def now_ms
      (Time.now.to_f * 1000).to_i
    end
  end
end
