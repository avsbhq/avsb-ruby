# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Avsb
  # SSE streaming client using Ruby's stdlib Net::HTTP.
  #
  # Connects to an SSE endpoint and yields parsed datafile Hashes to the
  # caller's block whenever a +data:+ line with a JSON datafile arrives.
  # Runs on its own background thread; call +stop+ to shut it down.
  #
  # Streaming is opt-in and the endpoint is server controlled: the publisher
  # writes +streamEndpoint+ into the datafile, and there is no default host to
  # fall back on. Never hardcode one. A Go SDK that defaulted to a host which
  # does not resolve gave every consumer an infinite reconnect loop.
  #
  # Usage:
  #   resolution = Avsb::Endpoints.resolve_stream_endpoint(
  #     datafile_stream_endpoint: client.datafile["streamEndpoint"]
  #   )
  #   if resolution.available?
  #     ticket_url = Avsb::Endpoints.stream_ticket_url(resolution.endpoint, sdk_key)
  #     stream = Avsb::Streaming.new(ticket_url, logger: logger)
  #     stream.connect { |datafile| client.replace_datafile(datafile) }
  #   else
  #     logger.warn(resolution.reason)
  #   end
  #
  #   # at shutdown
  #   stream.stop
  class Streaming
    DEFAULT_RETRY_DELAY = 5 # seconds
    READ_TIMEOUT        = 60
    STOP_JOIN_TIMEOUT   = 5

    def initialize(url, headers: {}, logger: nil)
      @url        = url
      @headers    = headers
      @logger     = logger
      @running    = false
      @thread     = nil
      @stop_mutex = Mutex.new
      @stop_cv    = ConditionVariable.new
    end

    # Start the SSE loop in a background thread.
    # Calls +block+ with the parsed datafile Hash on every update event.
    def connect(&block)
      raise ArgumentError, "connect requires a block" unless block

      @running = true
      @thread  = Thread.new { run_loop(block) }
      @thread.abort_on_exception = false
      self
    end

    # Stop the SSE loop.
    #
    # Cooperative: the loop is asked to stop and joined rather than killed. A
    # killed thread can die mid-chunk and leave a half-parsed event behind.
    # The join is bounded, because a connection blocked in read has to wait
    # out READ_TIMEOUT before it notices.
    # @return [self]
    def stop
      @running = false
      @stop_mutex.synchronize { @stop_cv.broadcast }
      @thread&.join(STOP_JOIN_TIMEOUT)
      @thread = nil
      self
    end

    def running?
      @running && @thread&.alive?
    end

    private

    def run_loop(callback)
      while @running
        begin
          uri = URI.parse(@url)
          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                          read_timeout: READ_TIMEOUT) do |http|
            req = Net::HTTP::Get.new(uri.request_uri)
            req["Accept"]        = "text/event-stream"
            req["Cache-Control"] = "no-cache"
            @headers.each { |k, v| req[k] = v }

            http.request(req) do |resp|
              resp.read_body do |chunk|
                # Notice a stop request between chunks instead of only when
                # the connection drops.
                break unless @running

                chunk.each_line do |line|
                  next unless line.start_with?("data:")

                  raw = line.sub(/\Adata:\s*/, "").strip
                  next if raw.empty?

                  begin
                    datafile = JSON.parse(raw)
                    callback.call(datafile)
                  rescue JSON::ParserError
                    @logger&.warn("Avsb::Streaming: failed to parse SSE data")
                  end
                end
              end
            end
          end
        rescue StandardError => e
          @logger&.warn("Avsb::Streaming: connection error (#{e.class}: #{e.message}); " \
                        "retrying in #{DEFAULT_RETRY_DELAY}s")
          # Wait on the stop signal rather than sleeping, so stop does not
          # have to wait out the retry delay.
          @stop_mutex.synchronize { @stop_cv.wait(@stop_mutex, DEFAULT_RETRY_DELAY) } if @running
        end
      end
    end
  end
end
