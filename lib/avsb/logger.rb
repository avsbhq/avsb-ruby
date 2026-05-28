# frozen_string_literal: true

require "logger"

module Avsb
  # Thin wrapper around Ruby's stdlib Logger.
  # Accepts an optional prefix and log-level threshold.
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
  end
end
