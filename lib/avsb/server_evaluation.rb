# frozen_string_literal: true

require_relative "flag"
require_relative "decision_log"
require_relative "core/context_resolver"
require_relative "core/evaluate"
require_relative "core/types"

module Avsb
  # The evaluation pipeline for Avsb::Server.
  #
  # Order matters and is locked by
  # packages/avsb-conformance/fixtures/semantics/manifest.json:
  #
  #   1. no datafile        -> not_ready, with the caller's default
  #   2. sticky lookup      (client layer, here)
  #   3. datafile override  (evaluator)
  #   4. holdout            (evaluator)
  #   5. rules, in order    (evaluator)
  #   6. flag default       (evaluator)
  #
  # Mixed into Avsb::Server rather than living in client.rb so the client file
  # stays about the client's lifecycle. Everything here is private.
  module ServerEvaluation
    private

    def evaluate(flag_key, default_value, context)
      datafile = @mutex.synchronize { @datafile }
      return not_ready_flag(flag_key, default_value) unless datafile

      ctx     = normalise_context(context)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      reasons = []
      user_id = visitor_id_for(ctx)
      warn_empty_context_once(user_id)

      result = @sticky.lookup(datafile, flag_key, user_id, reasons) do |assignment, variation|
        record_sticky_exposure(datafile, flag_key, user_id, assignment, variation)
      end

      unless result
        result = Core::Evaluator.evaluate_flag(
          flag_key, default_value, ctx, datafile,
          on_exposure: exposure_hook,
          reasons: reasons,
          bandit_model_store: @bandit_model_store,
        )
        @sticky.save(datafile, flag_key, user_id, result)
      end

      elapsed = elapsed_micros_since(started)
      flag    = Avsb::Flag.from_result(result, duration_micros: elapsed)
      record_decision(flag_key, flag, ctx, reasons, elapsed)
      flag
    end

    # Evaluating before a datafile exists returns the caller's default with
    # source not_ready, unchanged and with its type intact. Reporting
    # not_found here would conflate "this flag does not exist" with "this SDK
    # never started", which is the difference someone needs in their first hour.
    def not_ready_flag(flag_key, default_value)
      @logger.warn(
        "avsb #{flag_key.inspect} was evaluated before the SDK was ready, returning your " \
        "default. Call wait_for_ready(timeout:) after constructing Avsb::Server, or pass " \
        "datafile: to bootstrap from one you already have."
      )
      Avsb::Flag.new(
        value:         default_value,
        variation_key: nil,
        source:        Core::EvaluationSource::NOT_READY,
        rule_id:       nil,
        rule_type:     nil,
        reasons:       ["AvsB SDK is not ready: no datafile is loaded yet"],
      )
    end

    def record_decision(flag_key, flag, ctx, reasons, elapsed)
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
        context_summary: Core::ContextResolver.summary(ctx),
        manually_fired:  false,
      )
      @decision_log.record(entry)
    end

    # Accepts a plain Hash (wire shape), an Avsb::SingleContext, or an
    # Avsb::MultiContext, and always returns a string-keyed Hash.
    def normalise_context(context)
      return { "kind" => "user", "key" => "" } if context.nil?

      if context.respond_to?(:to_h)
        context.to_h.transform_keys(&:to_s)
      else
        context
      end
    end

    # The bucketing identity: the user sub-context's key, falling back to the
    # first declared kind. The explicit empty check matters because "" is
    # truthy in Ruby and would otherwise stop the fallback that the reference
    # engine performs.
    def visitor_id_for(ctx)
      key = Core::ContextResolver.bucketing_key(ctx, "user")
      key.empty? ? Core::ContextResolver.primary_context_key(ctx) : key
    end

    # Once per process, name the exact call to add. Every caller who forgets
    # the context lands the whole fleet in one bucket, and the data looks
    # plausible right up to the moment someone tries to act on it.
    def warn_empty_context_once(user_id)
      return unless user_id.to_s.empty?
      return if self.class.warned_empty_context

      self.class.warned_empty_context = true
      @logger.warn(
        "avsb evaluated a flag with an empty context key, so every caller buckets " \
        "identically and experiment data will be meaningless. Pass a context, for example " \
        'context: { "kind" => "user", "key" => current_user.id.to_s }. ' \
        "This warning appears once per process."
      )
    end

    def elapsed_micros_since(started_nanos)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      ((now - started_nanos) / 1_000).round
    end
  end
end
