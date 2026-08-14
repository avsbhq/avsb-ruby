# avsb: Ruby SDK

Server-side Ruby SDK for [A vs B](https://app.avsb.cloud), the feature-flag and
experimentation platform.

Ruby 3.1 or later. Zero runtime dependencies. Rack middleware, Rails
integration, sticky bucketing, and an OpenFeature provider are included.

How it works: your process downloads one JSON datafile from a global CDN,
evaluates flags locally in microseconds, and posts exposures and conversions in
batches. There is no proxy to run and no request to A vs B on the hot path.

---

## 1. Install

Add to your Gemfile:

```ruby
gem "avsb"
```

Then:

```bash
bundle install
```

Gem name: `avsb`. Optional integrations are guard-required at instantiation, so
the gem loads without them:

| Integration | Gem |
|---|---|
| Redis sticky bucketing | `gem "redis", "~> 5.0"` |
| DynamoDB sticky bucketing | `gem "aws-sdk-dynamodb", "~> 1"` |
| OpenFeature | `gem "openfeature-sdk"` |
| Rack middleware | `gem "rack", "~> 3.0"` |

---

## 2. Quickstart

```ruby
require "avsb"

client = Avsb::Server.new(sdk_key: ENV.fetch("AVSB_SDK_KEY"))
client.wait_for_ready(timeout: 5)

flag = client.get_bool_flag(
  "checkout-v2",
  default_value: false,
  context: { "kind" => "user", "key" => "alice", "plan" => "pro" }
)

if flag.value
  # serve the new checkout
end

client.track("checkout_completed",
             context: { "kind" => "user", "key" => "alice" },
             revenue: 49.99)

at_exit { client.close }
```

One instance per process. It holds the datafile in memory, refreshes it in the
background, and batches events; building one per request throws away all three.

### Rails

Create `config/initializers/avsb.rb` yourself (there is no generator):

```ruby
Avsb.configure do |config|
  config.sdk_key          = ENV.fetch("AVSB_SDK_KEY")
  config.polling_interval = 60
end

Avsb.client = Avsb::Server.new(
  sdk_key: Avsb.configuration.sdk_key,
  logger: Rails.logger
)

at_exit { Avsb.client&.close }
```

Include the controller concern:

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include Avsb::Middleware::Rails::Controller
  # avsb_client is now available in controllers and views
end
```

```ruby
def show
  flag = avsb_client.get_bool_flag(
    "checkout-v2",
    default_value: false,
    context: { "kind" => "user", "key" => current_user.id.to_s,
               "plan" => current_user.plan }
  )
  @use_new_checkout = flag.value
end
```

---

## 3. SDK keys

An SDK key looks like `sdk_production_ttqm0eaj4vth1krcb2xn`: the prefix `sdk_`,
your environment name, then a generated id. Copy the key for the environment you
want from the A vs B dashboard, under Environments in the project sidebar.

```bash
export AVSB_SDK_KEY=sdk_production_ttqm0eaj4vth1krcb2xn
```

```ruby
client = Avsb::Server.new(sdk_key: ENV.fetch("AVSB_SDK_KEY"))
```

The SDK checks the shape at construction. A pasted dashboard URL, a truncated
copy, or an API token in this field logs an error naming the mistake, and the SDK
carries on, so the problem is visible before the datafile request 404s.

SDK keys are public identifiers: they name an environment and grant read access
to that environment's datafile, which is served from a CDN with no
authentication. That is by design and safe in a browser. It is not an API
credential: personal access tokens (`avsb_pat_...`) and service tokens
(`avsb_svc_...`) are secrets and must never appear in client code.

---

## 4. Context and identity

Every flag call takes a context. It is a plain Hash in the wire shape: string
keys, with `"kind"` and `"key"` required.

```ruby
context = {
  "kind"        => "user",
  "key"         => "alice",       # the bucketing identity
  "plan"        => "pro",         # targeting attributes, any JSON value
  "beta_tester" => true
}
```

`Avsb::EvalContext` builds one for you:

```ruby
Avsb::EvalContext.user("alice", plan: "pro").to_h
# => { "kind" => "user", "key" => "alice", "plan" => "pro" }
```

Evaluating with an empty `"key"` buckets every caller identically and makes
experiment data meaningless, so the SDK warns once per process and names the
call to add.

### Multi-context

```ruby
context = {
  "kind"         => "multi",
  "user"         => { "kind" => "user",         "key" => "alice" },
  "organization" => { "kind" => "organization", "key" => "acme",
                      "tier" => "enterprise" }
}

flag = client.get_bool_flag("enterprise-feature", default_value: false,
                            context: context)
```

When a rule sets `hashAttribute` to `organization.key`, everyone in the same
organisation gets the same variation regardless of their own user key. Audience
conditions scoped to a kind read only that sub-context, and a condition naming a
kind the context does not carry never matches.

---

## 5. Reading flags

Four typed getters. `default_value:` is required and has no default: it is what
you get when the flag is missing, the SDK is not ready, or the flag is off.

```ruby
# Avsb::Server#get_bool_flag(flag_key, default_value:, context: nil) -> Avsb::Flag
show_banner = client.get_bool_flag("promo-banner", default_value: false,
                                   context: context)

# Avsb::Server#get_string_flag(flag_key, default_value:, context: nil) -> Avsb::Flag
theme = client.get_string_flag("ui-theme", default_value: "light",
                               context: context)

# Avsb::Server#get_number_flag(flag_key, default_value:, context: nil) -> Avsb::Flag
max_retries = client.get_number_flag("max-retries", default_value: 3.0,
                                     context: context)

# Avsb::Server#get_json_flag(flag_key, default_value:, context: nil) -> Avsb::Flag
config = client.get_json_flag("api-config", default_value: {}, context: context)
```

Every getter returns an `Avsb::Flag`, never a bare value. Ruby is dynamically
typed, so the getters do not coerce: the value you get is whatever `JSON.parse`
produced for that variation. If a flag's variations hold strings and you call
`get_bool_flag`, `flag.value` is that string, not `true`. Read `flag.value` when
you want the value and `flag.enabled?` when you want a gate.

### `Avsb::Flag`

```ruby
flag = client.get_bool_flag("checkout-v2", default_value: false, context: context)

flag.value            # Object          the evaluated value, your type
flag.variation_key    # String, nil     nil for default, not_found, not_ready
flag.source           # String          why this value (see below)
flag.rule_id          # String, nil     the rule or holdout that decided
flag.rule_type        # String, nil     "ab_test", "targeted_delivery",
                      #                 "holdout", "bandit", or nil
flag.reasons          # Array<String>   frozen decision trail, in order
flag.evaluated_at     # Integer         milliseconds since the Unix epoch
flag.duration_micros  # Integer         microseconds spent evaluating
flag.enabled?         # true, false     aliased as #enabled
flag.exists?          # true, false     aliased as #exists
flag.to_h             # Hash{Symbol=>Object}
```

`flag.source` is one of:

| Source | Meaning |
|---|---|
| `"rule"` | A targeting rule or A/B test decided this. |
| `"holdout"` | The context is held out of this flag's experiments. |
| `"bandit"` | A bandit rule chose this arm. |
| `"sticky"` | A stored assignment was reused. |
| `"datafileOverride"` | An override saved in the dashboard for this user. |
| `"runtimeOverride"` | An override set in code at runtime. |
| `"default"` | No rule matched, so the flag's default variation was served. |
| `"disabled"` | The flag is switched off; its default variation was served. |
| `"not_found"` | The datafile was read and this key is not in it. |
| `"not_ready"` | There is no datafile yet, so your `default_value` came back. |

`enabled?` is true when the source is one of `rule`, `holdout`, `bandit`,
`sticky`, `datafileOverride`, or `runtimeOverride` **and** the value is truthy.
Truthy means what it means in JavaScript, because the reference engine is
TypeScript and every SDK must answer identically: `false`, `0`, `""`, and `nil`
are falsy, and everything else is truthy, including the strings `"0"` and
`"false"`, and empty arrays and hashes. A flag serving its default variation is
never enabled, however truthy that default is.

`exists?` is false for `not_found` and `not_ready`, and true for everything
else. A disabled flag exists: the customer turned it off.

### Decision log

```ruby
client.decision_log.entries.each do |entry|
  entry.flag_key        # String
  entry.value           # Object
  entry.source          # String
  entry.reasons         # Array<String>
  entry.context_summary # Array<Hash>  [{ kind:, key: }], attributes never logged
end
```

---

## 6. Lifecycle

```ruby
# Avsb::Server#new(sdk_key:, datafile: nil, logger: nil, cdn_host: nil,
#                  polling_interval: 60, sticky_bucket_service: nil,
#                  bandit_model_store: nil, events: true, on_ready: nil,
#                  on_error: nil, on_sticky_orphan: nil) -> Avsb::Server
```

Construction never blocks: the first fetch runs on a background thread. Find out
how it went in one of two ways.

```ruby
# Blocking, with a timeout.
result = client.wait_for_ready(timeout: 5)
# => { success: true, source: "network" }
# => { success: true, source: "bootstrap" }
# => { success: false, source: "error", error: #<RuntimeError ...> }
# => nil when the timeout expired first

# Or a callback, which fires immediately when the client is already ready.
client.on_ready { |result| Rails.logger.info("avsb ready: #{result[:source]}") }
client.on_error { |error| Sentry.capture_exception(error) }
```

```ruby
client.ready?               # true, false  a datafile is loaded and readable now
client.degraded?            # true, false  a refresh failed, so this datafile is older
client.init_result          # Hash, nil    the result above, nil until it settles
client.pending_event_count  # Integer      events queued and not yet sent
```

Refreshes run every `polling_interval` seconds (60 by default) with jittered
exponential backoff on failure, so a transient outage recovers on its own rather
than leaving the process serving defaults until someone restarts it. Pass
`polling_interval: nil` to never refresh.

```ruby
client.replace_datafile(new_datafile) # hot-swap, for streaming or your own fetch
client.flush                          # send queued events now
client.close                          # flush events, stop the refresh thread
```

`close` signals the background thread and joins it rather than killing it, so a
request in flight is not cut in half, and it flushes queued events so a
shutting-down process does not throw away the conversions it just recorded.

### Bootstrapping

Pass a datafile you already have and the client is ready immediately:

```ruby
client = Avsb::Server.new(sdk_key: ENV.fetch("AVSB_SDK_KEY"),
                          datafile: JSON.parse(File.read("datafile.json")))
```

---

## 7. Tracking events

```ruby
# Avsb::Server#track(event_name, context:, revenue: nil, value: nil) -> void
client.track("signup_completed", context: context)
client.track("checkout_completed", context: context, revenue: 49.99)
client.track("items_per_order", context: context, value: 3)
```

`event_name` is the metric key from your dashboard. An unknown key is stored, so
a typo shows up as an empty metric rather than an error. `revenue` is money in
decimal major units, for revenue metrics. `value` is the number for
average-value metrics. Both are optional; a plain conversion needs neither.

```ruby
# Avsb::Server#track_purchase(context, order) -> true, false
client.track_purchase(context, {
  "orderId"  => "ORD-1001",
  "total"    => 99.95,
  "currency" => "USD",
  "items"    => [{ "sku" => "SKU-1", "price" => 99.95, "quantity" => 1 }]
})
```

`"orderId"` and `"total"` are required; `"currency"`, `"subtotal"`,
`"shipping"`, `"tax"`, `"discount"`, `"coupon"`, `"test"`, and `"items"` are
optional. Orders send immediately rather than waiting for a batch.

Exposures are automatic. Every `ab_test`, bandit, and holdout decision records
one, so you do not call anything to make experiment results appear. Metric
events and exposures are batched, retried with jittered backoff, and flushed on
`close`. Pass `events: false` to turn all sending off.

---

## 8. Sticky bucketing

A sticky store keeps a user on the variation they first saw, even if traffic
allocations change later.

```ruby
client = Avsb::Server.new(
  sdk_key: ENV.fetch("AVSB_SDK_KEY"),
  sticky_bucket_service: Avsb::Sticky::Redis.new(Redis.new(url: ENV["REDIS_URL"]),
                                                ttl: 86_400 * 30)
)
```

Shipped stores: `Avsb::Sticky::InMemory`, `Avsb::Sticky::Redis` (needs the
`redis` gem), and `Avsb::Sticky::DynamoDB` (needs `aws-sdk-dynamodb`). Any object
with these two methods works:

```ruby
# lookup(user_id, flag_key) -> Hash, nil
#   { variation_id: String, rule_id: String, rule_type: String, assigned_at: Integer }
# save(user_id, flag_key, assignment) -> void   fire and forget
```

The store is read before the evaluator and written only after an `ab_test` rule
match, storing the variation **id**. A targeted delivery is a rollout, not an
assignment, so it is not stored. If a stored variation has since been deleted the
lookup is a miss; if its rule is gone the stored value is still served, with a
warning and no exposure, because the experiment it would be attributed to no
longer exists. Pass `on_sticky_orphan:` to observe that case.

---

## 9. Bandits

`bandit`-typed rules dispatch through the shared bandit engine. With no model
store supplied the SDK runs the algorithm's documented cold-start policy, which
is deterministic for a given datafile and context, so a configured bandit never
silently behaves as "no rules matched".

```ruby
store = Avsb::Core::Bandits::InMemoryModelStore.new
client = Avsb::Server.new(sdk_key: ENV.fetch("AVSB_SDK_KEY"),
                          bandit_model_store: store)
```

Every bandit rule that cannot dispatch (no config, an unresolvable `banditId`,
no actions, or an action pointing at a deleted variation) appends a reason
naming why, visible in `flag.reasons`.

---

## 10. Logging and failure

Pass anything that responds to `debug`, `info`, `warn`, and `error`:

```ruby
client = Avsb::Server.new(sdk_key: ENV.fetch("AVSB_SDK_KEY"), logger: Rails.logger)

# or the built-in wrapper
client = Avsb::Server.new(
  sdk_key: ENV.fetch("AVSB_SDK_KEY"),
  logger: Avsb::Logger.new($stdout, level: :debug, prefix: "avsb")
)
```

With no logger the SDK prints warnings to stderr in development and nothing in
production, detected from `RAILS_ENV`, `RACK_ENV`, or `APP_ENV`. Pass a logger
explicitly in production to keep the messages.

Failures name the exact value involved and how to reproduce them. A 404 datafile
prints the URL tried, why a 404 usually happens, and a `curl` that repeats the
request without the SDK in the way. A dropped event batch prints the endpoint,
the status, and a `curl` with the exact body.

Evaluation never raises. A missing flag, an unexpected type, or an SDK that is
not ready returns your `default_value` with a `source` that says which of those
it was.

---

## 11. Rack and pre-evaluating for server-rendered pages

```ruby
# config.ru
require "avsb"

client = Avsb::Server.new(sdk_key: ENV.fetch("AVSB_SDK_KEY"))
use Avsb::Middleware::Rack, client: client
run MyApp
```

```ruby
client = env["avsb.client"]
```

Evaluate everything a response needs at the top of the action and pass the values
to the view:

```ruby
def show
  ctx = { "kind" => "user", "key" => current_user.id.to_s }
  @flags = {
    new_checkout: avsb_client.get_bool_flag("checkout-v2", default_value: false,
                                           context: ctx),
    one_click: avsb_client.get_bool_flag("one-click-buy", default_value: false,
                                        context: ctx)
  }
end
```

```erb
<% if @flags[:new_checkout].value %>
  <%= render "checkout/new" %>
<% else %>
  <%= render "checkout/legacy" %>
<% end %>
```

---

## 12. Live updates over SSE

Polling is the default and needs no setup. Streaming is opt-in, and the endpoint
is server controlled: the publisher writes `streamEndpoint` into the datafile.
There is no default streaming host, so nothing ever connects to a host that does
not exist.

```ruby
resolution = Avsb::Endpoints.resolve_stream_endpoint(
  datafile_stream_endpoint: client.datafile["streamEndpoint"]
)

if resolution.available?
  ticket_url = Avsb::Endpoints.stream_ticket_url(resolution.endpoint,
                                                 ENV.fetch("AVSB_SDK_KEY"))
  stream = Avsb::Streaming.new(ticket_url)
  stream.connect { |datafile| client.replace_datafile(datafile) }
  at_exit { stream.stop }
else
  warn resolution.reason
end
```

---

## 13. Testing

Build a datafile and pass it as a bootstrap: no network, no background fetch.

```ruby
require "avsb"

RSpec.describe "checkout flag" do
  let(:datafile) do
    {
      "version" => 2,
      "sdkKey"  => "sdk_test_conformancefixture01",
      "flags"   => [{
        "id" => "flag_checkout", "key" => "checkout-v2", "type" => "boolean",
        "enabled" => true, "defaultVariationId" => "var_off",
        "variations" => [
          { "id" => "var_off", "key" => "off", "value" => false },
          { "id" => "var_on",  "key" => "on",  "value" => true }
        ],
        "overrides" => [],
        "rules" => [{
          "id" => "rule_all", "type" => "targeted_delivery", "enabled" => true,
          "audienceIds" => [], "hashAttribute" => "user.key",
          "trafficAllocation" => nil,
          "variations" => [{ "variationId" => "var_on", "percentage" => 1 }]
        }]
      }],
      "audiences" => []
    }
  end

  let(:client) do
    Avsb::Server.new(sdk_key: "sdk_test_conformancefixture01", datafile: datafile,
                     events: false, polling_interval: nil)
  end

  after { client.close }

  it "serves the on variation" do
    flag = client.get_bool_flag("checkout-v2", default_value: false,
                                context: { "kind" => "user", "key" => "alice" })

    expect(flag.value).to be true
    expect(flag.enabled?).to be true
    expect(flag.source).to eq("rule")
  end
end
```

`events: false` keeps tests off the network entirely.
`Avsb::TestUtils::SpyStickyBucketService` records every lookup and save for
assertions:

```ruby
spy = Avsb::TestUtils::SpyStickyBucketService.new(
  preset: { "alice:checkout-v2" => { variation_id: "var_on", rule_id: "rule_ab",
                                     rule_type: "ab_test", assigned_at: 1 } }
)
client = Avsb::Server.new(sdk_key: "sdk_test_conformancefixture01",
                          datafile: datafile, sticky_bucket_service: spy,
                          events: false, polling_interval: nil)

client.get_bool_flag("checkout-v2", default_value: false,
                     context: { "kind" => "user", "key" => "alice" })

expect(spy.lookups).to include({ user_id: "alice", flag_key: "checkout-v2" })
```

Run the suite:

```bash
bundle exec rspec
```

`spec/conformance_spec.rb` runs the shared cross-language corpus from
`packages/avsb-conformance` (or the copy vendored into `spec/vendor`), asserting
that this evaluator produces identical values, sources, and reason strings to the
reference TypeScript engine. Missing fixtures fail the suite rather than being
skipped.

---

## 14. OpenFeature

```ruby
require "open_feature/sdk"

OpenFeature::SDK.configure do |config|
  config.set_provider(Avsb::OpenFeatureProvider.new(client))
end
```

The provider maps `targetingKey` onto the context key; `rule`, `holdout`, and
`bandit` onto `TARGETING_MATCH`; `sticky` onto `CACHED`; the two override
sources onto `STATIC`; and an SDK with no datafile yet onto
`PROVIDER_NOT_READY`.

---

## 15. Migrating

### From the LaunchDarkly Ruby SDK

```ruby
# LaunchDarkly
client = LaunchDarkly::LDClient.new("sdk-key")
value  = client.variation("checkout-v2", { key: "alice", custom: { plan: "pro" } }, false)
```

```ruby
# A vs B
client = Avsb::Server.new(sdk_key: ENV.fetch("AVSB_SDK_KEY"))
value  = client.get_bool_flag("checkout-v2", default_value: false,
                              context: { "kind" => "user", "key" => "alice",
                                         "plan" => "pro" }).value
```

Differences that matter: getters are typed and take keyword arguments, the return
value is an `Avsb::Flag` carrying the full decision trail rather than a bare
value, and multi-context is a plain Hash instead of a builder.

### From the Statsig Ruby SDK

```ruby
# Statsig
gate = Statsig.check_gate(StatsigUser.new({ "userID" => "alice" }), "checkout-v2")
Statsig.log_event(user, "purchase", value: 49.99)
```

```ruby
# A vs B
ctx  = { "kind" => "user", "key" => "alice" }
gate = client.get_bool_flag("checkout-v2", default_value: false, context: ctx).enabled?
client.track("purchase", context: ctx, revenue: 49.99)
```
