# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

require_relative "flag"
require_relative "decision_log"
require_relative "logger"
require_relative "core/evaluate"

module Avsb
  # Avsb::Server: server-side feature flag client.
  #
  # Quickstart:
  #   client = Avsb::Server.new(sdk_key: ENV["AVSB_SDK_KEY"])
  #   client.on_ready { |result| puts "SDK ready: #{result}" }
  #   flag = client.get_bool_flag("my-feature", default_value: false,
  #                                context: { "kind" => "user", "key" => "alice" })
  class Server
    DATAFILE_URL_TEMPLATE = "https://cdn.avsb.cloud/v1/datafiles/%s.json"

    attr_reader :datafile, :decision_log

    def initialize(sdk_key:, datafile: nil, logger: nil, sticky_bucket_service: nil,
                   polling_interval: 60, on_ready: nil, on_error: nil)
      @sdk_key              = sdk_key
      @datafile             = datafile
      @logger               = logger || Avsb::Logger.new($stdout, level: :warn, prefix: "avsb")
      @sticky_bucket_service = sticky_bucket_service
      @polling_interval     = polling_interval
      @decision_log         = Avsb::DecisionLog.new
      @ready_callbacks      = on_ready ? [on_ready] : []
      @error_callbacks      = on_error ? [on_error] : []
      @mutex                = Mutex.new
      @poll_thread          = nil

      if @datafile
        # Bootstrap mode — datafile supplied directly.
        fire_ready({ success: true, source: "bootstrap" })
      else
        # Fetch datafile asynchronously.
        Thread.new { fetch_and_start_polling }
      end
    end

    # Register a block called when the SDK is ready to serve.
    def on_ready(&block)
      @ready_callbacks << block
      self
    end

    # Register a block called on initialisation or polling errors.
    def on_error(&block)
      @error_callbacks << block
      self
    end

    # Evaluate a boolean flag.
    # +default_value:+ is required (keyword argument with no default).
    def get_bool_flag(flag_key, default_value:, context: nil)
      evaluate(flag_key, default_value, context)
    end

    # Evaluate a string flag.
    def get_string_flag(flag_key, default_value:, context: nil)
      evaluate(flag_key, default_value, context)
    end

    # Evaluate a numeric flag.
    def get_number_flag(flag_key, default_value:, context: nil)
      evaluate(flag_key, default_value, context)
    end

    # Evaluate a JSON flag.
    def get_json_flag(flag_key, default_value:, context: nil)
      evaluate(flag_key, default_value, context)
    end

    # Track a metric event (fire-and-forget).
    def track(event_name, value: nil, properties: nil, context: nil)
      @logger.debug("track", { event: event_name, value: value })
      nil
    end

    # Identify a context (fire-and-forget).
    def identify(context)
      @logger.debug("identify", { context: context })
      nil
    end

    # Replace the in-memory datafile (useful for streaming + bootstrap).
    def replace_datafile(new_datafile)
      @mutex.synchronize { @datafile = new_datafile }
      nil
    end

    # Stop background polling.
    def close
      @poll_thread&.kill
      @poll_thread = nil
      self
    end

    private

    def evaluate(flag_key, default_value, context)
      df = @mutex.synchronize { @datafile }
      unless df
        @logger.warn("evaluate called before datafile is available; returning default")
        return Avsb::Flag.new(
          value:         default_value,
          variation_key: nil,
          source:        "not_found",
          rule_id:       nil,
          rule_type:     nil,
          reasons:       ["datafile not yet loaded"],
        )
      end

      ctx      = normalise_context(context)
      started  = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      reasons  = []
      result   = Avsb::Core::Evaluator.evaluate_flag(flag_key, default_value, ctx, df, reasons: reasons)
      elapsed  = ((Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - started) / 1_000).round

      flag = Avsb::Flag.from_result(result, duration_micros: elapsed)

      # Record to decision log.
      context_summary = build_context_summary(ctx)
      entry = Avsb::DecisionLogEntry.new(
        flag_key:        flag_key,
        value:           flag.value,
        variation_key:   flag.variation_key,
        source:          flag.source,
        rule_id:         flag.rule_id,
        rule_type:       flag.rule_type,
        reasons:         reasons,
        evaluated_at:    flag.evaluated_at,
        duration_micros: elapsed,
        context_summary: context_summary,
        manually_fired:  false,
      )
      @decision_log.record(entry)

      flag
    end

    def normalise_context(context)
      return { "kind" => "user", "key" => "" } if context.nil?

      # Accept plain Hash (wire shape) or Avsb::SingleContext / Avsb::MultiContext.
      if context.respond_to?(:to_h)
        h = context.to_h
        # Ensure string keys throughout.
        h.transform_keys(&:to_s)
      else
        context
      end
    end

    def build_context_summary(ctx)
      if ctx["kind"] == "multi"
        ctx.each_with_object([]) do |(kind, sub), acc|
          next if kind == "kind"
          next unless sub.is_a?(Hash)

          acc << { kind: sub["kind"] || kind, key: sub["key"].to_s }
        end
      else
        [{ kind: ctx["kind"] || "user", key: ctx["key"].to_s }]
      end
    end

    def fetch_and_start_polling
      url = DATAFILE_URL_TEMPLATE % @sdk_key
      begin
        df = fetch_datafile(url)
        @mutex.synchronize { @datafile = df }
        fire_ready({ success: true, source: "network" })
      rescue StandardError => e
        @logger.error("initial datafile fetch failed: #{e.message}")
        fire_error(e)
        fire_ready({ success: false, source: "error", error: e, degraded: true })
      end

      start_polling(url)
    end

    def start_polling(url)
      @poll_thread = Thread.new do
        loop do
          sleep(@polling_interval)
          begin
            df = fetch_datafile(url)
            @mutex.synchronize { @datafile = df }
          rescue StandardError => e
            @logger.warn("polling error: #{e.message}")
          end
        end
      end
      @poll_thread.abort_on_exception = false
    end

    def fetch_datafile(url)
      uri  = URI.parse(url)
      resp = Net::HTTP.get_response(uri)
      raise "HTTP #{resp.code} fetching datafile from #{url}" unless resp.is_a?(Net::HTTPSuccess)

      JSON.parse(resp.body)
    end

    def fire_ready(result)
      @ready_callbacks.each { |cb| cb.call(result) }
    end

    def fire_error(err)
      @error_callbacks.each { |cb| cb.call(err) }
    end
  end

  # Module-level configuration and singleton client.
  class Configuration
    attr_accessor :sdk_key, :logger, :sticky_bucket_service, :polling_interval

    def initialize
      @sdk_key              = nil
      @logger               = nil
      @sticky_bucket_service = nil
      @polling_interval     = 60
    end
  end

  class << self
    def configure
      @configuration ||= Configuration.new
      yield @configuration if block_given?
      @configuration
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def client
      @client
    end

    def client=(c)
      @client = c
    end
  end
end
