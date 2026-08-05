# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Avsb
  # The SDK's only outbound HTTP surface, so timeouts, proxy handling, and
  # the User-Agent are decided once.
  #
  # Net::HTTP with no explicit timeout can hang forever, which turns a slow
  # CDN into a stalled Puma worker. Every call here carries one.
  module Http
    # One response, whatever the transport did.
    #
    #   status       #=> Integer  HTTP status, 0 when the request never landed
    #   body         #=> String   response body, "" on a transport error
    #   error        #=> String, nil  transport error message
    #   retry_after  #=> String, nil  Retry-After header, verbatim
    Response = Struct.new(:status, :body, :error, :retry_after) do
      # @return [Boolean] 2xx
      def ok?
        status >= 200 && status < 300
      end

      # @return [Object, nil] parsed JSON body, or nil when it will not parse
      def json
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
    end

    DEFAULT_TIMEOUT = 10

    class << self
      # GET a URL.
      #
      # @param url [String]
      # @param timeout [Numeric] seconds, applied to connect, read, and write
      # @param headers [Hash{String=>String}]
      # @return [Avsb::Http::Response]
      def get(url, timeout: DEFAULT_TIMEOUT, headers: {})
        request(url, timeout: timeout) do |uri|
          req = Net::HTTP::Get.new(uri)
          headers.each { |k, v| req[k] = v }
          req["User-Agent"] = user_agent
          req
        end
      end

      # POST a JSON body.
      #
      # @param url [String]
      # @param body [String] a serialised JSON document
      # @param timeout [Numeric] seconds
      # @param headers [Hash{String=>String}]
      # @return [Avsb::Http::Response]
      def post_json(url, body, timeout: DEFAULT_TIMEOUT, headers: {})
        request(url, timeout: timeout) do |uri|
          req = Net::HTTP::Post.new(uri)
          headers.each { |k, v| req[k] = v }
          req["Content-Type"] = "application/json"
          req["User-Agent"]   = user_agent
          req.body = body
          req
        end
      end

      # @return [String] "avsb-ruby/<version>", built from the gem version
      def user_agent
        "avsb-ruby/#{Avsb::VERSION}"
      end

      private

      def request(url, timeout:)
        uri = URI.parse(url)
        # find_proxy honours http_proxy / https_proxy / no_proxy, which is how
        # most Ruby deployments reach the internet from inside a VPC.
        proxy = uri.find_proxy
        http  = if proxy
                  Net::HTTP.new(uri.host, uri.port, proxy.host, proxy.port,
                                proxy.user, proxy.password)
                else
                  Net::HTTP.new(uri.host, uri.port)
                end
        http.use_ssl      = uri.scheme == "https"
        http.open_timeout = timeout
        http.read_timeout = timeout
        http.write_timeout = timeout if http.respond_to?(:write_timeout=)

        response = http.start { |session| session.request(yield(uri)) }
        Response.new(response.code.to_i, response.body.to_s, nil, response["retry-after"])
      rescue StandardError => e
        Response.new(0, "", "#{e.class}: #{e.message}", nil)
      end
    end
  end
end
