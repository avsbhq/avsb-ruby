# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Avsb
  # SSE streaming client using Ruby's stdlib Net::HTTP.
  #
  # Connects to an SSE endpoint and yields parsed datafile Hashes to the
  # caller's block whenever a `data:` line with a JSON datafile arrives.
  # Runs on its own background thread; call +stop+ to shut it down.
  #
  # Usage:
  #   stream = Avsb::Streaming.new("https://stream.avsb.cloud/v1/sse?sdkKey=...")
  #   stream.connect do |datafile|
  #     client.replace_datafile(datafile)
  #   end
  #   # later …
  #   stream.stop
  class Streaming
    DEFAULT_RETRY_DELAY = 5 # seconds
    READ_TIMEOUT        = 60

    def initialize(url, headers: {}, logger: nil)
      @url         = url
      @headers     = headers
      @logger      = logger
      @running     = false
      @thread      = nil
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

    def stop
      @running = false
      @thread&.kill
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
          @logger&.warn("Avsb::Streaming: connection error (#{e.class}: #{e.message}); retrying in #{DEFAULT_RETRY_DELAY}s")
          sleep(DEFAULT_RETRY_DELAY) if @running
        end
      end
    end
  end
end
