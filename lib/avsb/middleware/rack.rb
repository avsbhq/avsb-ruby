# frozen_string_literal: true

module Avsb
  module Middleware
    # Rack middleware that mounts an Avsb::Server client and makes it
    # available via the Rack env under the key "avsb.client".
    #
    # Usage (config.ru):
    #   require "avsb"
    #   use Avsb::Middleware::Rack, client: Avsb::Server.new(sdk_key: ENV["AVSB_SDK_KEY"])
    class Rack
      ENV_KEY = "avsb.client"

      def initialize(app, client:)
        @app    = app
        @client = client
      end

      def call(env)
        env[ENV_KEY] = @client
        @app.call(env)
      end
    end
  end
end
