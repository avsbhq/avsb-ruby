# avsb: Ruby SDK

Server-side Ruby SDK for the [A vs B](https://app.avsb.cloud) feature-flag and experimentation platform.

Ruby 3.1+. Rack middleware, Rails integration, sticky bucketing, OpenFeature provider.

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

Gem name: `avsb`. Version: `1.0.0`. **Runtime requirement:** Ruby 3.1 or later.

Optional integrations (guard-required at instantiation; not loaded unless the gem is present):

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

client = Avsb::Server.new(sdk_key: ENV["AVSB_SDK_KEY"])

client.on_ready do |result|
  puts "SDK ready (source=#{result[:source]})"
end

flag = client.get_bool_flag(
  "checkout-v2",
  default_value: false,
  context: { "kind" => "user", "key" => "alice", "plan" => "pro" }
)

if flag.value
  # serve new checkout
end
```

### Rails quickstart

Generate the initializer:

```bash
rails g avsb:install
```

This creates `config/initializers/avsb.rb`:

```ruby
Avsb.configure do |config|
  config.sdk_key          = ENV["AVSB_SDK_KEY"]
  config.polling_interval = 60
end

Avsb.client = Avsb::Server.new(sdk_key: Avsb.configuration.sdk_key)
```

Include the controller concern:

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include Avsb::Middleware::Rails::Controller
  # avsb_client is now available in every controller and view helper
end
```

Evaluate flags in an action:

```ruby
def show
  flag = avsb_client.get_bool_flag(
    "checkout-v2",
    default_value: false,
    context: { "kind" => "user", "key" => current_user.id.to_s, "plan" => current_user.plan }
  )
  @use_new_checkout = flag.value
end
```

---

## 3. SDK keys

Get a **server SDK key** from your A vs B project's Environments page. Store it in an environment variable; never hard-code it.

```bash
export AVSB_SDK_KEY=sdk-...
```

```ruby
client = Avsb::Server.new(sdk_key: ENV["AVSB_SDK_KEY"])
```

Never use the public (client-side) SDK key in server code. Server SDK keys carry elevated trust and must not be exposed in browser bundles or HTML responses.

---

## 4. Identity

`Avsb::Server` accepts a context hash on every flag call. The hash follows the wire-protocol shape (string keys, `"kind"` and `"key"` required):

```ruby
context = { "kind" => "user", "key" => "alice", "plan" => "pro", "beta_tester" => true }
```

### `identify(context)`: notify downstream integrations

```ruby
client.identify(context)
```

### `on_ready` / `on_error`: lifecycle callbacks

```ruby
client = Avsb::Server.new(
  sdk_key: ENV["AVSB_SDK_KEY"],
  on_ready: ->(result) { Rails.logger.info("avsb ready: #{result}") },
  on_error: ->(err) { Sentry.capture_exception(err) }
)
```

Or register callbacks after construction using the fluent block form:

```ruby
client
  .on_ready { |result| Rails.logger.info("avsb ready") }
  .on_error  { |err|    Rails.logger.error("avsb error: #{err}") }
```

### `replace_datafile(new_datafile)`: hot-swap the datafile

Use with the streaming integration to apply real-time datafile updates:

```ruby
client.replace_datafile(new_datafile)
```

### `close`: stop background polling

```ruby
client.close
```

---

## 5. Multi-context

```ruby
context = {
  "kind"         => "multi",
  "user"         => { "kind" => "user",         "key" => "alice" },
  "organization" => { "kind" => "organization", "key" => "acme", "tier" => "enterprise" },
}

flag = client.get_bool_flag("enterprise-feature", default_value: false, context: context)
```

When a rule specifies `hashAttribute: "organization.key"`, all members of the same organisation receive the same variation regardless of their individual user key.

---

## 6. Reading flags

### Typed shortcut methods

All flag methods use keyword arguments. `default_value:` is required and has no default.

```ruby
show_banner  = client.get_bool_flag("promo-banner",  default_value: false,    context: context)
theme        = client.get_string_flag("ui-theme",    default_value: "light",  context: context)
max_retries  = client.get_number_flag("max-retries", default_value: 3.0,      context: context)
config       = client.get_json_flag("api-config",    default_value: {},        context: context)
```

Each shortcut returns the raw typed value extracted from the `Avsb::Flag` envelope.

### `Avsb::Flag`: full evaluation envelope

```ruby
flag = client.get_bool_flag("checkout-v2", default_value: false, context: context)

flag.value           # T: the evaluated value (Boolean here)
flag.variation_key   # String or nil: matched variation key
flag.source          # String: "rule" / "holdout" / "default" / "not_found" / ...
flag.rule_id         # String or nil: matched rule id
flag.rule_type       # String or nil: "ab_test" / "targeted_delivery" / "holdout" / "bandit"
flag.reasons         # Array<String>: always frozen
flag.evaluated_at    # Integer: ms epoch
flag.duration_micros # Integer: microseconds spent in evaluator
flag.enabled?        # Boolean: source=="rule" && !!value
flag.exists?         # Boolean: source != "not_found"
```

`enabled?` is also aliased as `enabled` for contexts where the question-mark form is inconvenient.

### Decision log

After processing a request, flush the decision log to retrieve all evaluations:

```ruby
entries = client.decision_log.entries
# Each entry is an Avsb::DecisionLogEntry with the same fields as Avsb::Flag
# plus context_summary: [{ kind:, key: }]; attributes are never logged.
```

---

## 7. Tracking events

```ruby
client.track(
  "purchase_completed",
  context: context,
  value: 49.99,
  properties: { plan: "pro", currency: "usd" }
)
```

`value` maps to the numeric metric quantity (generalises `revenue`). `properties` is forwarded to the collection endpoint. Both are optional.

---

## 8. Error handling

`Avsb::Server` accepts a logger that responds to `debug(msg, details = {})`, `info`, `warn`, and `error`. By default it uses `Avsb::Logger` wrapping `$stdout` at `:warn` level:

```ruby
require "logger"

rails_logger = Rails.logger  # any Logger-compatible object
client = Avsb::Server.new(sdk_key: ENV["AVSB_SDK_KEY"], logger: rails_logger)
```

Or use the built-in structured logger with a custom level:

```ruby
client = Avsb::Server.new(
  sdk_key: ENV["AVSB_SDK_KEY"],
  logger:  Avsb::Logger.new($stdout, level: :debug, prefix: "avsb")
)
```

**`on_error` callback** fires on initial fetch failures and polling errors:

```ruby
client = Avsb::Server.new(
  sdk_key:  ENV["AVSB_SDK_KEY"],
  on_error: ->(err) { Sentry.capture_exception(err) }
)
```

When the initial fetch fails, `on_ready` is called with `{ success: false, source: "error", degraded: true }`. The client continues returning default values and retries on the next polling cycle.

---

## 9. Pre-evaluating flags for server-rendered responses

Pre-evaluate all flags needed for a response at the top of the controller action and pass the resolved values to your view:

```ruby
def show
  ctx = { "kind" => "user", "key" => current_user.id.to_s, "plan" => current_user.plan }

  @flags = {
    new_checkout: avsb_client.get_bool_flag("checkout-v2",   default_value: false, context: ctx),
    one_click:    avsb_client.get_bool_flag("one-click-buy", default_value: false, context: ctx),
  }
end
```

In ERB:

```erb
<% if @flags[:new_checkout].value %>
  <%= render "checkout/new" %>
<% else %>
  <%= render "checkout/legacy" %>
<% end %>
```

### Rack middleware

```ruby
# config.ru
require "avsb"

client = Avsb::Server.new(sdk_key: ENV["AVSB_SDK_KEY"])
use Avsb::Middleware::Rack, client: client

run MyApp
```

Access in request handlers:

```ruby
client = env["avsb.client"]
```

### SSE streaming (live datafile updates)

```ruby
stream = Avsb::Streaming.new(
  "https://stream.avsb.cloud/v1/sse?sdkKey=#{ENV['AVSB_SDK_KEY']}"
)
stream.connect do |new_datafile|
  client.replace_datafile(new_datafile)
end

# At shutdown:
stream.stop
```

---

## 10. Graceful shutdown

Use an `ensure` block to stop background polling:

```ruby
client = Avsb::Server.new(sdk_key: ENV["AVSB_SDK_KEY"])
begin
  # serve requests
ensure
  client.close
end
```

In a Rails application, stop the client in a `config.after_initialize` block or an `ActiveSupport::Reloader`:

```ruby
# config/initializers/avsb.rb
at_exit { Avsb.client&.close }
```

`close` kills the polling thread. Any buffered decision log entries should be flushed before calling `close` if you have a log-forwarding integration:

```ruby
entries = client.decision_log.entries
send_to_analytics(entries)
client.close
```

---

## 11. Testing

Use `Avsb::TestUtils::InMemoryDatafileLoader` to serve a fake datafile without network calls:

```ruby
require "avsb"

RSpec.describe "checkout flag" do
  let(:datafile) do
    {
      "version"  => 2,
      "sdkKey"   => "sdk-test",
      "flags"    => [
        {
          "id"                 => "flag_checkout-v2",
          "key"                => "checkout-v2",
          "type"               => "boolean",
          "enabled"            => true,
          "defaultVariationId" => "var_off",
          "variations"         => [
            { "id" => "var_off", "key" => "off", "value" => false },
            { "id" => "var_on",  "key" => "on",  "value" => true  },
          ],
          "rules" => [],
        },
      ],
      "audiences" => [],
    }
  end

  let(:client) { Avsb::Server.new(sdk_key: "sdk-test", datafile: datafile) }

  it "returns a Flag result" do
    ctx  = { "kind" => "user", "key" => "alice" }
    flag = client.get_bool_flag("checkout-v2", default_value: false, context: ctx)

    expect(flag).to be_a(Avsb::Flag)
    expect(flag.exists?).to be true
    expect(flag.source).to be_in(["rule", "default"])
  end
end
```

`SpyStickyBucketService` records every `lookup` and `save` call for assertions:

```ruby
spy = Avsb::TestUtils::SpyStickyBucketService.new(
  preset: { "alice:checkout-v2" => { variation_id: "var_on", rule_id: "r1" } }
)
client = Avsb::Server.new(sdk_key: "sdk-test", datafile: datafile, sticky_bucket_service: spy)

client.get_bool_flag("checkout-v2", default_value: false, context: ctx)

expect(spy.lookups).to include(hash_including(user_id: "alice", flag_key: "checkout-v2"))
```

Run the test suite:

```bash
bundle exec rspec
```

The conformance suite in `spec/conformance_spec.rb` runs all shared JSON fixtures from `packages/avsb-conformance/` automatically.

---

## 12. Migration from LaunchDarkly / Statsig

### From LaunchDarkly Ruby SDK

```ruby
# LaunchDarkly
require "ldclient-rb"

client = LaunchDarkly::LDClient.new("sdk-key")
user   = { key: "alice", custom: { plan: "pro" } }
value  = client.variation("checkout-v2", user, false)
```

```ruby
# A vs B
require "avsb"

client = Avsb::Server.new(sdk_key: ENV["AVSB_SDK_KEY"])
ctx    = { "kind" => "user", "key" => "alice", "plan" => "pro" }
value  = client.get_bool_flag("checkout-v2", default_value: false, context: ctx).value
```

```ruby
# LaunchDarkly (multi-context)
multi_context = LaunchDarkly::LDContext.create_multi(
  LaunchDarkly::LDContext.create({ kind: "user", key: "alice" }),
  LaunchDarkly::LDContext.create({ kind: "organization", key: "acme", tier: "enterprise" })
)
```

```ruby
# A vs B (multi-context)
ctx = {
  "kind"         => "multi",
  "user"         => { "kind" => "user",         "key" => "alice" },
  "organization" => { "kind" => "organization", "key" => "acme", "tier" => "enterprise" },
}
```

Key differences:
- `get_bool_flag` uses keyword arguments (`default_value:`, `context:`). No untyped `.variation()`.
- The return value is an `Avsb::Flag` object. Access `.value` for the raw Boolean, `.enabled?` for a gate check, `.source` for the decision audit.
- Multi-context is a plain Hash, not a builder class.

### From Statsig Ruby SDK

```ruby
# Statsig
require "statsig"

Statsig.initialize("secret-key")
user  = StatsigUser.new({ "userID" => "alice", "custom" => { "plan" => "pro" } })
gate  = Statsig.check_gate(user, "checkout-v2")
```

```ruby
# A vs B
ctx  = { "kind" => "user", "key" => "alice", "plan" => "pro" }
gate = client.get_bool_flag("checkout-v2", default_value: false, context: ctx).enabled?
```

```ruby
# Statsig (track event)
Statsig.log_event(user, "purchase", value: 49.99, metadata: { "plan" => "pro" })
```

```ruby
# A vs B (track event)
client.track("purchase", context: ctx, value: 49.99, properties: { plan: "pro" })
```
