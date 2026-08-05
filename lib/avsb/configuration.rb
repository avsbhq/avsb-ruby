# frozen_string_literal: true

require_relative "datafile_poller"

module Avsb
  # Module-level configuration, used by the Rails integration so an
  # initializer can declare settings before the client is built.
  #
  #   Avsb.configure do |config|
  #     config.sdk_key = ENV.fetch("AVSB_SDK_KEY")
  #   end
  #
  #   Avsb.client = Avsb::Server.new(sdk_key: Avsb.configuration.sdk_key)
  class Configuration
    # @return [String, nil]
    attr_accessor :sdk_key
    # @return [Object, nil]
    attr_accessor :logger
    # @return [Object, nil]
    attr_accessor :sticky_bucket_service
    # @return [Numeric, nil]
    attr_accessor :polling_interval

    def initialize
      @sdk_key = nil
      @logger  = nil
      @sticky_bucket_service = nil
      @polling_interval = DatafilePoller::DEFAULT_POLLING_INTERVAL
    end
  end

  class << self
    # @yieldparam configuration [Avsb::Configuration]
    # @return [Avsb::Configuration]
    def configure
      @configuration ||= Configuration.new
      yield @configuration if block_given?
      @configuration
    end

    # @return [Avsb::Configuration]
    def configuration
      @configuration ||= Configuration.new
    end

    # The process-wide client, if the application chooses to keep one here.
    # Nothing in the SDK sets this; the Rails integration reads it.
    # @return [Avsb::Server, nil]
    attr_accessor :client
  end
end
