# frozen_string_literal: true

module Avsb
  module Core
    # Evaluation source: why a flag has the value it has.
    #
    # The full public set, locked by
    # packages/avsb-conformance/fixtures/semantics/manifest.json. Spellings
    # outside this list must never reach a caller: `override` and
    # `runtime_override` are internal evaluator names in other ports and are
    # mapped at the SDK boundary, and `not_started`, `not_initialized`, and
    # `uninitialized` are invented not-ready spellings that must all be
    # NOT_READY.
    module EvaluationSource
      DATAFILE_OVERRIDE = "datafileOverride"
      RUNTIME_OVERRIDE  = "runtimeOverride"
      STICKY            = "sticky"
      RULE              = "rule"
      HOLDOUT           = "holdout"
      BANDIT            = "bandit"
      DEFAULT           = "default"
      NOT_FOUND         = "not_found"
      DISABLED          = "disabled"
      # No datafile to look in: init has not completed, the fetch failed with
      # no bootstrap datafile, or the client was closed. Distinct from
      # NOT_FOUND, which means the datafile was read and the key was absent.
      NOT_READY         = "not_ready"

      # The six sources that mean a real decision produced this value.
      # Everything else is a fallback, and a fallback is never "enabled".
      DECIDED = [RULE, HOLDOUT, BANDIT, RUNTIME_OVERRIDE, DATAFILE_OVERRIDE, STICKY].freeze

      # Sources where the flag key is not known to exist.
      UNKNOWN = [NOT_FOUND, NOT_READY].freeze

      ALL = [
        DATAFILE_OVERRIDE, RUNTIME_OVERRIDE, STICKY, RULE, HOLDOUT, BANDIT,
        DEFAULT, NOT_FOUND, DISABLED, NOT_READY
      ].freeze
    end

    # Rule type constants.
    module RuleType
      TARGETED_DELIVERY = "targeted_delivery"
      AB_TEST           = "ab_test"
      HOLDOUT           = "holdout"
      BANDIT            = "bandit"
    end

    # Per-call evaluation options.
    #
    # Two members, both real. EXCLUDE_VARIABLES, IGNORE_STICKY_BUCKET, and
    # ENABLED_FLAGS_ONLY were declared here and honoured nowhere, so they are
    # gone rather than left as a promise the SDK does not keep.
    module DecideOption
      DISABLE_EXPOSURE = "DISABLE_EXPOSURE"
      INCLUDE_REASONS  = "INCLUDE_REASONS"
    end
  end
end
