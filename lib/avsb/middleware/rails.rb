# frozen_string_literal: true

module Avsb
  module Middleware
    # Rails integration.
    #
    # 1. Railtie: auto-loads when railties is available.
    # 2. Controller concern: adds `avsb_client` helper to any controller that
    #    includes `Avsb::Middleware::Rails::Controller`.
    #
    # Quickstart (config/initializers/avsb.rb):
    #
    #   Avsb.configure do |config|
    #     config.sdk_key = ENV["AVSB_SDK_KEY"]
    #   end
    #
    # In ApplicationController:
    #
    #   class ApplicationController < ActionController::Base
    #     include Avsb::Middleware::Rails::Controller
    #   end
    #
    # Then in any action or view helper:
    #
    #   flag = avsb_client.get_bool_flag("my-feature", default_value: false,
    #                                     context: { "kind" => "user", "key" => current_user.id.to_s })
    module Rails
      # ApplicationController concern.
      module Controller
        def self.included(base)
          base.helper_method :avsb_client if base.respond_to?(:helper_method)
        end

        # Returns the Avsb::Server instance configured via Avsb.configure.
        def avsb_client
          Avsb.client
        end
      end

      # Railtie: wires up the initializer and middleware when Rails is present.
      if defined?(::Rails::Railtie)
        class Railtie < ::Rails::Railtie
          initializer "avsb.middleware" do |app|
            if Avsb.respond_to?(:client) && Avsb.client
              app.middleware.use(Avsb::Middleware::Rack, client: Avsb.client)
            end
          end
        end
      end
    end
  end
end
