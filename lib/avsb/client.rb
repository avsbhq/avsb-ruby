# frozen_string_literal: true

require_relative "configuration"
require_relative "decision_log"
require_relative "endpoints"
require_relative "flag"
require_relative "heartbeat"
require_relative "http"
require_relative "logger"
require_relative "datafile_poller"
require_relative "sdk_key_shape"
require_relative "server_evaluation"
require_relative "server_events"
require_relative "sticky_pipeline"
require_relative "tracker"
require_relative "core/context_resolver"
require_relative "core/evaluate"
require_relative "core/types"

module Avsb
  # Avsb::Server: the server-side feature flag client.
  #
  # Quickstart:
  #
  #   client = Avsb::Server.new(sdk_key: ENV.fetch("AVSB_SDK_KEY"))
  #   client.wait_for_ready(timeout: 5)
  #
  #   flag = client.get_bool_flag("checkout-v2", default_value: false,
  #                               context: { "kind" => "user", "key" => "alice" })
  #   flag.value      #=> true or false
  #   flag.enabled?   #=> decided by a rule AND truthy
  #
  #   client.track("signup_completed", context: { "kind" => "user", "key" => "alice" })
  #   client.close    # flushes queued events, stops the refresh thread
  #
  # One instance per process. It holds the datafile in memory, refreshes it in
  # the background, and batches events; constructing one per request throws
  # away both.
  class Server
    include ServerEvaluation
    include ServerEvents

    # @return [Hash, nil] the datafile currently in memory
    # @return [Avsb::DecisionLog] every decision this client has made
    attr_reader :datafile, :decision_log

    class << self
      # Tracks the once-per-process warnings so they stay once per process.
      # @api private
      attr_accessor :warned_empty_context

      # Clear the once-per-process warning latches. For tests.
      # @return [void]
      def reset_process_warnings!
        self.warned_empty_context = false
      end
    end

    # @param sdk_key [String] the environment SDK key, +sdk_<env>_<id>+
    # @param datafile [Hash, nil] a bootstrap datafile. Supplied means "serve
    #   from this immediately"; refreshes still run unless polling is off.
    # @param logger [Object, nil] responds to debug/info/warn/error. Defaults
    #   to console at warn level in development, silent in production.
    # @param cdn_host [String, nil] override the CDN origin (proxy, local dev)
    # @param polling_interval [Numeric] seconds between refreshes. Pass nil to
    #   never refresh (bootstrap-only).
    # @param sticky_bucket_service [Object, nil] responds to
    #   +lookup(user_id, flag_key)+ and +save(user_id, flag_key, assignment)+
    # @param bandit_model_store [Object, nil] responds to +get_model(key)+ and
    #   +update_model(key, model)+. Without one, bandit rules run their
    #   cold-start policy.
    # @param events [Boolean] send exposures and conversions to ingest
    # @param on_ready [Proc, nil] called once with the init result Hash
    # @param on_error [Proc, nil] called with every fetch or refresh error
    # @param on_sticky_orphan [Proc, nil] called with
    #   +{flag_key:, user_id:, assignment:}+ when a stored assignment points
    #   at a rule the datafile no longer carries
    def initialize(sdk_key:, datafile: nil, logger: nil, cdn_host: nil,
                   polling_interval: DatafilePoller::DEFAULT_POLLING_INTERVAL,
                   sticky_bucket_service: nil, bandit_model_store: nil, events: true,
                   on_ready: nil, on_error: nil, on_sticky_orphan: nil)
      @sdk_key      = sdk_key.to_s
      @logger       = logger || Avsb::Logger.default
      @datafile     = datafile
      @decision_log = Avsb::DecisionLog.new
      @bandit_model_store = bandit_model_store
      @events_enabled = events
      @polling_interval = polling_interval

      @sticky = StickyPipeline.new(
        service: sticky_bucket_service,
        logger: @logger,
        on_orphan: on_sticky_orphan,
      )

      @ready_callbacks = on_ready ? [on_ready] : []
      @error_callbacks = on_error ? [on_error] : []
      @mutex     = Mutex.new
      @tracker   = nil
      @init_result = nil
      @degraded  = false
      @heartbeat = Heartbeat.new(sdk_key: @sdk_key, logger: @logger)

      @ready_mutex = Mutex.new
      @ready_cv    = ConditionVariable.new

      # Log a key that cannot be right, then carry on with it: the datafile
      # fetch is the real arbiter, and a shape we do not recognise today may
      # be valid tomorrow.
      key_message = SdkKeyShape.message_for(@sdk_key)
      @logger.error(key_message) if key_message

      @poller = build_poller(cdn_host)

      if @datafile
        start_events
        fire_ready({ success: true, source: "bootstrap" })
        @heartbeat.send_if_due(@datafile)
      end

      start_background_init
    end

    # Register a block called once the first init attempt settles.
    # Fires immediately when the client is already ready.
    # @return [self]
    def on_ready(&block)
      result = @mutex.synchronize { @init_result }
      if result
        block.call(result)
        return self
      end

      @ready_callbacks << block
      self
    end

    # Register a block called on every fetch or refresh error.
    # @return [self]
    def on_error(&block)
      @error_callbacks << block
      self
    end

    # Block until the first init attempt settles.
    #
    # @param timeout [Numeric] seconds
    # @return [Hash, nil] the init result, or nil when the timeout expired
    #   first. Shape: +{success:, source:, error: (only on failure)}+ where
    #   source is "network", "bootstrap", or "error".
    def wait_for_ready(timeout: 10)
      deadline = monotonic_now + timeout
      @ready_mutex.synchronize do
        while @mutex.synchronize { @init_result }.nil?
          remaining = deadline - monotonic_now
          break if remaining <= 0

          @ready_cv.wait(@ready_mutex, remaining)
        end
      end
      @mutex.synchronize { @init_result }
    end

    # @return [Boolean] a datafile is loaded and flags are readable now
    def ready?
      !@mutex.synchronize { @datafile }.nil?
    end

    # @return [Boolean] true when the last refresh failed and the datafile in
    #   memory is therefore older than the published one
    def degraded?
      @mutex.synchronize { @degraded }
    end

    # @return [Hash, nil] the init result, nil until the first attempt settles
    def init_result
      @mutex.synchronize { @init_result }
    end

    # Evaluate a boolean flag.
    # @param flag_key [String]
    # @param default_value [Boolean] returned for every non-decision
    # @param context [Hash, Avsb::SingleContext, Avsb::MultiContext, nil]
    # @return [Avsb::Flag]
    def get_bool_flag(flag_key, default_value:, context: nil)
      evaluate(flag_key, default_value, context)
    end

    # Evaluate a string flag.
    # @return [Avsb::Flag]
    def get_string_flag(flag_key, default_value:, context: nil)
      evaluate(flag_key, default_value, context)
    end

    # Evaluate a numeric flag.
    # @return [Avsb::Flag]
    def get_number_flag(flag_key, default_value:, context: nil)
      evaluate(flag_key, default_value, context)
    end

    # Evaluate a JSON flag. The value is whatever JSON.parse produced: a
    # Hash, an Array, or a scalar.
    # @return [Avsb::Flag]
    def get_json_flag(flag_key, default_value:, context: nil)
      evaluate(flag_key, default_value, context)
    end

    # Record a conversion.
    #
    # Queued and sent in batches; +close+ flushes what is left.
    #
    # @param event_name [String] the metric key from the dashboard. An
    #   unknown key is stored, so a typo shows up as an empty metric.
    # @param context [Hash, Avsb::SingleContext, Avsb::MultiContext] whose
    #   key attributes the event to a visitor
    # @param revenue [Numeric, nil] money in decimal major units, for revenue
    #   metrics. nil for a non-revenue conversion.
    # @param value [Numeric, nil] the numeric value for average-value
    #   metrics. nil when the metric counts.
    # @return [void]
    def track(event_name, context:, revenue: nil, value: nil)
      unless @tracker
        @logger.warn(
          "avsb track(#{event_name.inspect}) was dropped: the SDK is not ready yet, so " \
          "there is no ingest endpoint to send to. Call wait_for_ready before tracking, " \
          "or pass datafile: to bootstrap."
        )
        return
      end

      ctx = normalise_context(context)
      @tracker.queue_metric({
        "visitorId" => visitor_id_for(ctx),
        "eventName" => event_name.to_s,
        "revenue"   => revenue,
        "value"     => value,
        "timestamp" => now_ms,
        "pageUrl"   => "",
      })
    end

    # Record a purchase. Sent immediately, not batched.
    #
    # @param context [Hash, Avsb::SingleContext, Avsb::MultiContext]
    # @param order [Hash] string keys. +"orderId"+ and +"total"+ are
    #   required; +"currency"+, +"subtotal"+, +"shipping"+, +"tax"+,
    #   +"discount"+, +"coupon"+, +"test"+, and +"items"+ are optional.
    # @return [Boolean] true when ingest accepted the order
    def track_purchase(context, order)
      unless @tracker
        @logger.warn("avsb track_purchase was dropped: the SDK is not ready yet.")
        return false
      end

      @tracker.track_purchase(visitor_id_for(normalise_context(context)), order)
    end

    # Send queued events now.
    # @return [void]
    def flush
      @tracker&.flush
    end

    # @return [Integer] events queued and not yet sent
    def pending_event_count
      @tracker&.pending_count || 0
    end

    # Replace the in-memory datafile (bootstrap refresh, or a streaming push).
    # @param new_datafile [Hash]
    # @return [void]
    def replace_datafile(new_datafile)
      apply_datafile(new_datafile)
      nil
    end

    # Stop the refresh thread and flush queued events.
    #
    # Cooperative: the refresh thread is signalled and joined rather than
    # killed, and the tracker sends what it has before the process exits.
    # @return [self]
    def close
      @poller&.close
      @tracker&.close
      @tracker = nil
      self
    end

    private

    # Returns nil when no datafile URL can be built at all, which today means
    # an empty SDK key. The SDK then serves defaults and says why, rather than
    # taking the host application down at boot over a missing environment
    # variable.
    def build_poller(cdn_host)
      DatafilePoller.new(
        sdk_key: @sdk_key,
        logger: @logger,
        cdn_host: cdn_host || Avsb::Endpoints::DEFAULT_CDN_HOST,
        polling_interval: @polling_interval || DatafilePoller::DEFAULT_POLLING_INTERVAL,
        on_update: ->(df) { apply_datafile(df) },
        on_error: ->(err) { handle_refresh_error(err) },
      )
    rescue ArgumentError => e
      @logger.error(e.message)
      nil
    end

    # Init runs off the caller's thread so constructing a client never blocks
    # boot. Use wait_for_ready or on_ready to find out how it went.
    def start_background_init
      if @poller.nil?
        unless @datafile
          error = ArgumentError.new(
            "AvsB was constructed without a usable SDK key, so no datafile can be " \
            "fetched and every flag returns your default value."
          )
          fire_ready({ success: false, source: "error", error: error })
        end
        return nil
      end

      thread = Thread.new do
        run_initial_fetch unless @datafile
        @poller.start unless @polling_interval.nil?
      rescue StandardError => e
        @logger.error("avsb init failed unexpectedly: #{e.class}: #{e.message}")
        fire_ready({ success: false, source: "error", error: e })
      end
      thread.abort_on_exception = false
      thread
    end

    def run_initial_fetch
      result = @poller.fetch_once
      if result[:datafile]
        apply_datafile(result[:datafile])
        fire_ready({ success: true, source: "network" })
      else
        @logger.error(result[:error].message)
        fire_error(result[:error])
        # No datafile and no bootstrap: every evaluation is not_ready until a
        # later refresh succeeds. success is false, and degraded stays false
        # because there is nothing stale to serve.
        fire_ready({ success: false, source: "error", error: result[:error] })
      end
    end

    def apply_datafile(new_datafile)
      @mutex.synchronize do
        @datafile = new_datafile
        @degraded = false
      end
      start_events
      @tracker&.update_collect_endpoint(collect_endpoint_from(new_datafile))
      @heartbeat.send_if_due(new_datafile)
    end

    def handle_refresh_error(error)
      @mutex.synchronize { @degraded = true if @datafile }
      fire_error(error)
    end

    def fire_ready(result)
      callbacks = nil
      @mutex.synchronize do
        return if @init_result

        @init_result = result
        callbacks = @ready_callbacks
        @ready_callbacks = []
      end
      @ready_mutex.synchronize { @ready_cv.broadcast }
      callbacks.each do |cb|
        cb.call(result)
      rescue StandardError => e
        @logger.error("avsb on_ready callback raised: #{e.class}: #{e.message}")
      end
    end

    def fire_error(err)
      @error_callbacks.each do |cb|
        cb.call(err)
      rescue StandardError => e
        @logger.error("avsb on_error callback raised: #{e.class}: #{e.message}")
      end
    end

    def now_ms
      (Time.now.to_f * 1000).to_i
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
