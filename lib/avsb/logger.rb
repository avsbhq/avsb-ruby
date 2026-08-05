# frozen_string_literal: true

require "logger"

module Avsb
  # Thin wrapper around Ruby's stdlib Logger.
  #
  # Accepts an optional prefix and level threshold. Any object responding to
  # +debug+, +info+, +warn+, and +error+ can be passed to Avsb::Server
  # instead, including Rails.logger.
  class Logger
    LEVELS = %w[debug info warn error].freeze

    def initialize(output = $stdout, level: :info, prefix: "avsb")
      @logger = ::Logger.new(output)
      @logger.level = ::Logger.const_get(level.to_s.upcase)
      @prefix = prefix.to_s
    end

    LEVELS.each do |lvl|
      define_method(lvl) do |message, data = nil|
        msg = @prefix.empty? ? message : "[#{@prefix}] #{message}"
        msg += " #{data.inspect}" if data
        @logger.public_send(lvl, msg)
      end
    end

    # Returns a child logger with an extended prefix.
    def child(sub_prefix)
      self.class.new(@logger.instance_variable_get(:@logdev)&.dev || $stdout,
                     level: @logger.level,
                     prefix: "#{@prefix}.#{sub_prefix}")
    end

    # The logger Avsb::Server uses when the caller passes none.
    #
    # Console at warn level in development, silence in production (spec
    # section 1.2). Warn level is what you want while wiring the SDK up: a
    # wrong SDK key, a 404 datafile, or a dropped event batch all say so on
    # stderr instead of vanishing. In production the host application owns
    # its log stream, so pass +logger:+ explicitly to keep the messages.
    #
    # Production is detected from RAILS_ENV, RACK_ENV, or APP_ENV.
    #
    # @return [Avsb::Logger, Avsb::NoopLogger]
    def self.default
      return NoopLogger.new if production?

      new($stderr, level: :warn, prefix: "avsb")
    end

    # @return [Boolean]
    def self.production?
      env = ENV["RAILS_ENV"] || ENV["RACK_ENV"] || ENV["APP_ENV"]
      env.to_s.downcase == "production"
    end
  end

  # Drops everything. The production default.
  class NoopLogger
    Avsb::Logger::LEVELS.each do |lvl|
      define_method(lvl) { |_message, _data = nil| nil }
    end

    def child(_sub_prefix)
      self
    end
  end
end
