# frozen_string_literal: true

module Avsb
  module Core
    # Evaluation source constants (§2.12).
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
    end

    # Rule type constants (§2.7).
    module RuleType
      TARGETED_DELIVERY = "targeted_delivery"
      AB_TEST           = "ab_test"
      HOLDOUT           = "holdout"
      BANDIT            = "bandit"
    end

    # Decide option constants (§2.11).
    module DecideOption
      DISABLE_EXPOSURE    = "DISABLE_EXPOSURE"
      INCLUDE_REASONS     = "INCLUDE_REASONS"
      EXCLUDE_VARIABLES   = "EXCLUDE_VARIABLES"
      IGNORE_STICKY_BUCKET = "IGNORE_STICKY_BUCKET"
      ENABLED_FLAGS_ONLY  = "ENABLED_FLAGS_ONLY"
    end
  end
end
