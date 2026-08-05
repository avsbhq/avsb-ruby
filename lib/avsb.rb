# frozen_string_literal: true

require_relative "avsb/version"
require_relative "avsb/endpoints"
require_relative "avsb/core/types"
require_relative "avsb/core/js_value"
require_relative "avsb/core/hash"
require_relative "avsb/core/context_resolver"
require_relative "avsb/core/audience_commerce"
require_relative "avsb/core/audience"
require_relative "avsb/core/holdouts"
require_relative "avsb/core/bandits"
require_relative "avsb/core/bandit_dispatch"
require_relative "avsb/core/evaluate"
require_relative "avsb/flag"
require_relative "avsb/context"
require_relative "avsb/decision_log"
require_relative "avsb/logger"
require_relative "avsb/http"
require_relative "avsb/backoff"
require_relative "avsb/sdk_key_shape"
require_relative "avsb/configuration"
require_relative "avsb/datafile_poller"
require_relative "avsb/heartbeat"
require_relative "avsb/tracker"
require_relative "avsb/sticky_pipeline"
require_relative "avsb/server_evaluation"
require_relative "avsb/server_events"
require_relative "avsb/test_utils"
require_relative "avsb/streaming"
require_relative "avsb/client"
require_relative "avsb/middleware/rack"
require_relative "avsb/middleware/rails"
require_relative "avsb/sticky/memory"
require_relative "avsb/sticky/redis"
require_relative "avsb/sticky/dynamodb"
require_relative "avsb/openfeature_provider"

# Avsb: the A vs B Ruby SDK.
#
# Public surface:
#   Avsb::Server:              server-side feature flag client
#   Avsb::Flag:                one evaluation result
#   Avsb::EvalContext:         context builder helpers
#   Avsb::SingleContext:       single-context value type
#   Avsb::MultiContext:        multi-context value type
#   Avsb::Endpoints:           data-plane hosts and URL builders
#   Avsb::Configuration:       module-level settings for the Rails integration
#   Avsb::Tracker:             batched exposure and conversion sender
#   Avsb::DatafilePoller:      datafile fetch plus refresh loop
#   Avsb::Heartbeat:           SDK liveness pings
#   Avsb::StickyPipeline:      client-layer sticky bucketing
#   Avsb::SdkKeyShape:         SDK key shape check and its message
#   Avsb::Backoff:             shared retry curve with jitter
#   Avsb::Http:                the SDK's only outbound HTTP surface
#   Avsb::Logger:              stdlib logger wrapper, plus Avsb::NoopLogger
#   Avsb::DecisionLog:         ordered decision log
#   Avsb::Streaming:           SSE datafile streaming client
#   Avsb::TestUtils:           InMemoryDatafileLoader, SpyStickyBucketService
#   Avsb::Sticky::InMemory:    in-memory sticky bucket service
#   Avsb::Sticky::Redis:       Redis-backed sticky bucket service (optional)
#   Avsb::Sticky::DynamoDB:    DynamoDB-backed sticky bucket service (optional)
#   Avsb::Middleware::Rack:    Rack middleware
#   Avsb::Middleware::Rails:   Rails Railtie plus controller concern
#   Avsb::OpenFeatureProvider: OpenFeature provider (optional)
#   Avsb::Core::Evaluator:     the evaluation engine
#   Avsb::Core::Audience:      audience condition evaluator
#   Avsb::Core::Holdouts:      holdout evaluator
#   Avsb::Core::Bandits:       bandit engine
#   Avsb::Core::Hash:          MurmurHash3
#   Avsb::Core::JsValue:       JavaScript truthiness and number semantics
#   Avsb::Core::ContextResolver: context kinds, keys, and dotted paths
module Avsb
end
