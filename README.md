# avsb — Ruby SDK

Server-side Ruby SDK for the [A vs B](https://avsb.cloud) feature flag and A/B experiment platform.

**Ruby >= 3.1 required.**

---

## Installation

Add to your Gemfile:

```ruby
gem "avsb"
```

Then:

```bash
bundle install
```

---

## Quick start (plain Ruby)

```ruby
require "avsb"

client = Avsb::Server.new(sdk_key: ENV["AVSB_SDK_KEY"])

client.on_ready do |result|
  puts "SDK ready (source=#{result[:source]})"
end

flag = client.get_bool_flag(
  "my-feature",
  default_value: false,
  context: { "kind" => "user", "key" => current_user_id }
)

puts flag.value      # => true / false
puts flag.source     # => "rule" / "default" / "not_found" …
puts flag.enabled?   # => true when source=="rule" && value is truthy
```

---

## Quick start (Rails)

**`config/initializers/avsb.rb`**

```ruby
require "avsb"

Avsb.configure do |config|
  config.sdk_key            = ENV["AVSB_SDK_KEY"]
  config.polling_interval   = 60         # seconds
  # config.sticky_bucket_service = Avsb::Sticky::Redis.new(Redis.new, ttl: 86_400)
end

Avsb.client = Avsb::Server.new(sdk_key: Avsb.configuration.sdk_key)
```

**`app/controllers/application_controller.rb`**

```ruby
class ApplicationController < ActionController::Base
  include Avsb::Middleware::Rails::Controller
  # now `avsb_client` is available in every controller and view helper
end
```

**In a controller action:**

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

## Multi-context evaluation

```ruby
context = {
  "kind"         => "multi",
  "user"         => { "kind" => "user", "key" => "u_123" },
  "organization" => { "kind" => "organization", "key" => "org_acme", "tier" => "enterprise" },
}

flag = client.get_bool_flag("enterprise-feature", default_value: false, context: context)
```

---

## Flag result object (`Avsb::Flag`)

| Method / Attribute | Type | Description |
|--------------------|------|-------------|
| `value` | `T` | Variation value typed against the default |
| `variation_key` | `String?` | Variation key, or `nil` for default/not_found |
| `source` | `String` | One of `rule`, `holdout`, `datafileOverride`, `disabled`, `default`, `not_found`, `sticky`, `bandit` |
| `rule_id` | `String?` | ID of the matching rule |
| `rule_type` | `String?` | `targeted_delivery`, `ab_test`, `holdout`, or `bandit` |
| `reasons` | `Array<String>` | Explanation of the decision |
| `enabled?` | `Boolean` | `source == "rule" && value` |
| `exists?` | `Boolean` | `source != "not_found"` |

---

## Sticky bucketing

```ruby
# In-memory (dev/test)
sticky = Avsb::Sticky::InMemory.new

# Redis (production)
# gem "redis", "~> 5.0"
sticky = Avsb::Sticky::Redis.new(Redis.new(url: ENV["REDIS_URL"]), ttl: 86_400 * 30)

# DynamoDB
# gem "aws-sdk-dynamodb", "~> 1"
sticky = Avsb::Sticky::DynamoDB.new(
  Aws::DynamoDB::Client.new(region: "us-east-1"),
  table_name: "avsb_sticky",
  ttl_days: 30
)

client = Avsb::Server.new(sdk_key: ENV["AVSB_SDK_KEY"], sticky_bucket_service: sticky)
```

---

## OpenFeature

```ruby
# gem "openfeature-sdk"
require "open_feature/sdk"
require "avsb"

OpenFeature::SDK.configure do |config|
  config.set_provider(Avsb::OpenFeatureProvider.new(avsb_client))
end
```

---

## Streaming (SSE)

```ruby
stream = Avsb::Streaming.new(
  "https://stream.avsb.cloud/v1/sse?sdkKey=#{ENV["AVSB_SDK_KEY"]}"
)
stream.connect do |datafile|
  client.replace_datafile(datafile)
end
# later …
stream.stop
```

---

## Running the test suite

```bash
bundle exec rspec
```

---

## Optional dependencies

All optional integrations guard-require their gems at instantiation time so the SDK loads without them installed:

| Integration | Gem |
|-------------|-----|
| Redis sticky bucketing | `gem "redis", "~> 5.0"` |
| DynamoDB sticky bucketing | `gem "aws-sdk-dynamodb", "~> 1"` |
| OpenFeature | `gem "openfeature-sdk"` |
| Rack middleware | `gem "rack", "~> 3.0"` |
| Rails integration | included with Rails |
