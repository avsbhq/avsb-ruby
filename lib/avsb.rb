# frozen_string_literal: true

require_relative "avsb/version"
require_relative "avsb/core/types"
require_relative "avsb/core/hash"
require_relative "avsb/core/audience"
require_relative "avsb/core/holdouts"
require_relative "avsb/core/evaluate"
require_relative "avsb/core/bandits"
require_relative "avsb/core/big_segments"
require_relative "avsb/flag"
require_relative "avsb/context"
require_relative "avsb/decision_log"
require_relative "avsb/logger"
require_relative "avsb/test_utils"
require_relative "avsb/streaming"
require_relative "avsb/client"
require_relative "avsb/middleware/rack"
require_relative "avsb/middleware/rails"
require_relative "avsb/sticky/memory"
require_relative "avsb/sticky/redis"
require_relative "avsb/sticky/dynamodb"
require_relative "avsb/openfeature_provider"

# Avsb — A vs B Ruby SDK.
#
# Public surface:
#   Avsb::Server             — server-side feature flag client
#   Avsb::Flag               — evaluation result value object
#   Avsb::EvalContext        — context builder helpers
#   Avsb::SingleContext      — single-context value type
#   Avsb::MultiContext       — multi-context value type
#   Avsb::Core::Hash         — MurmurHash3 implementation
#   Avsb::Core::Evaluator    — flag evaluation engine
#   Avsb::Core::Audience     — audience condition evaluator
#   Avsb::Core::Holdouts     — holdout evaluation engine
#   Avsb::Core::Bandits      — bandit evaluation engine
#   Avsb::Sticky::InMemory   — in-memory sticky bucket service
#   Avsb::Sticky::Redis      — Redis-backed sticky bucket service (optional)
#   Avsb::Sticky::DynamoDB   — DynamoDB-backed sticky bucket service (optional)
#   Avsb::Middleware::Rack   — Rack middleware
#   Avsb::Middleware::Rails  — Rails Railtie + controller concern
#   Avsb::Streaming          — SSE datafile streaming client
#   Avsb::DecisionLog        — ordered decision log
#   Avsb::TestUtils          — test helpers (InMemoryDatafileLoader, SpyStickyBucketService)
#   Avsb::OpenFeatureProvider — OpenFeature provider (optional)
module Avsb
end
