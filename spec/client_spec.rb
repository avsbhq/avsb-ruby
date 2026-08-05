# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe Avsb::Server do
  let(:sdk_key) { "sdk_production_clientfixture01" }
  let(:posts)   { [] }
  let(:fetched) { [] }
  let(:logger)  { instance_double(Avsb::Logger, debug: nil, info: nil, warn: nil, error: nil) }

  # An ab_test rule at 100 percent allocation with a single 100 percent
  # variation, so every context is bucketed and an exposure always fires.
  let(:datafile) do
    {
      "version" => 2, "projectType" => "FEATURE_FLAG", "sdkKey" => sdk_key,
      "environmentKey" => "production", "publishedAt" => "2026-05-29T00:00:00.000Z",
      "collectEndpoint" => "https://ingest.avsb.cloud",
      "heartbeatEndpoint" => "https://app.avsb.cloud/api/sdk/heartbeat",
      "flags" => [{
        "id" => "flag_1", "key" => "checkout-v2", "type" => "boolean", "enabled" => true,
        "defaultVariationId" => "var_off",
        "variations" => [
          { "id" => "var_off", "key" => "off", "value" => false },
          { "id" => "var_on", "key" => "on", "value" => true },
        ],
        "overrides" => [],
        "rules" => [{
          "id" => "rule_ab", "type" => "ab_test", "enabled" => true, "audienceIds" => [],
          "hashAttribute" => "user.key", "trafficAllocation" => 1,
          "variations" => [{ "variationId" => "var_on", "percentage" => 1 }],
        }],
      }],
      "audiences" => []
    }
  end

  let(:context) { { "kind" => "user", "key" => "alice" } }

  before do
    described_class.reset_process_warnings!
    allow(Avsb::Http).to receive(:post_json) do |url, body, **_kwargs|
      posts << { url: url, body: JSON.parse(body) }
      Avsb::Http::Response.new(202, "", nil, nil)
    end
    allow(Avsb::Http).to receive(:get) do |url, **_kwargs|
      fetched << url
      Avsb::Http::Response.new(200, JSON.generate(datafile), nil, nil)
    end
  end

  # polling_interval: nil keeps the refresh loop out of the examples; the
  # initial fetch (or the bootstrap) is all these need.
  def build(**overrides)
    described_class.new(sdk_key: sdk_key, logger: logger, polling_interval: nil, **overrides)
  end

  def bootstrapped(**overrides)
    build(datafile: datafile, **overrides)
  end

  def exposures_in(requests)
    requests.select { |r| r[:url].end_with?("/v1/collect/batch") }
            .flat_map { |r| r[:body]["events"] }
  end

  describe "construction" do
    it "logs an actionable error for a key that cannot be right, and still works" do
      client = described_class.new(sdk_key: "nonsense", datafile: datafile, logger: logger,
                                  polling_interval: nil)
      expect(logger).to have_received(:error).with(/does not look like an SDK key/)
      expect(client.get_bool_flag("checkout-v2", default_value: false, context: context).value)
        .to be true
      client.close
    end

    it "serves defaults and says why when no key was passed at all" do
      client = described_class.new(sdk_key: "", logger: logger, polling_interval: nil)
      flag = client.get_bool_flag("checkout-v2", default_value: false, context: context)

      expect(flag.source).to eq("not_ready")
      expect(client.init_result[:success]).to be false
      expect(logger).to have_received(:error).with(/without an SDK key/)
      client.close
    end

    it "fetches from the canonical datafile URL" do
      client = build
      client.wait_for_ready(timeout: 2)

      expect(fetched).to eq(["https://cdn.avsb.cloud/#{sdk_key}/datafile.json"])
      expect(client.ready?).to be true
      client.close
    end

    it "reports success:false with source=error when the fetch fails and nothing is bootstrapped" do
      allow(Avsb::Http).to receive(:get)
        .and_return(Avsb::Http::Response.new(404, "", nil, nil))
      client = build
      result = client.wait_for_ready(timeout: 2)

      expect(result[:success]).to be false
      expect(result[:source]).to eq("error")
      expect(result[:error].message).to include("HTTP 404")
      # degraded is reserved for serving something stale; there is nothing to
      # serve here, so it is not degraded, it is not ready.
      expect(client.degraded?).to be false
      client.close
    end

    it "is ready immediately with a bootstrap datafile" do
      client = bootstrapped
      expect(client.ready?).to be true
      expect(client.init_result).to eq({ success: true, source: "bootstrap" })
      client.close
    end
  end

  describe "evaluation" do
    it "returns the bucketed variation with the full envelope" do
      client = bootstrapped
      flag = client.get_bool_flag("checkout-v2", default_value: false, context: context)

      expect(flag.value).to be true
      expect(flag.variation_key).to eq("on")
      expect(flag.source).to eq("rule")
      expect(flag.rule_type).to eq("ab_test")
      expect(flag.rule_id).to eq("rule_ab")
      expect(flag.enabled?).to be true
      expect(flag.exists?).to be true
      expect(flag.reasons.first).to include("matched (ab_test)")
      client.close
    end

    it "records the decision in the decision log" do
      client = bootstrapped
      client.get_bool_flag("checkout-v2", default_value: false, context: context)

      entry = client.decision_log.entries.first
      expect(entry.flag_key).to eq("checkout-v2")
      expect(entry.source).to eq("rule")
      expect(entry.context_summary).to eq([{ kind: "user", key: "alice" }])
      client.close
    end

    it "warns once per process about an empty context key" do
      client = bootstrapped
      3.times { client.get_bool_flag("checkout-v2", default_value: false) }

      expect(logger).to have_received(:warn).with(/empty context key/).once
      client.close
    end
  end

  describe "exposure recording" do
    it "sends an ab_test exposure with the locked field names" do
      client = bootstrapped
      client.get_bool_flag("checkout-v2", default_value: false, context: context)
      client.flush

      event = exposures_in(posts).first
      expect(event).not_to be_nil
      expect(event["eventName"]).to eq("flag_exposure")
      expect(event["visitorId"]).to eq("alice")
      expect(event["experimentId"]).to eq("rule_ab")
      expect(event["variationId"]).to eq("var_on")
      expect(event["revenue"]).to be_nil
      expect(event["pageUrl"]).to eq("")
      expect(event["properties"]).to eq({ "flagKey" => "checkout-v2", "flagId" => "flag_1" })
      client.close
    end

    it "sends a holdout exposure under its own event name" do
      held = datafile.merge(
        "holdouts" => [{
          "id" => "holdout_q2", "key" => "q2-2026-holdout", "trafficAllocation" => 1,
          "hashAttribute" => "user.key", "flagIds" => ["flag_1"],
          "defaultVariationByFlag" => { "flag_1" => "var_off" },
        }]
      )
      client = build(datafile: held)
      client.get_bool_flag("checkout-v2", default_value: false, context: context)
      client.flush

      event = exposures_in(posts).first
      expect(event["eventName"]).to eq("flag_holdout_exposure")
      expect(event["experimentId"]).to eq("holdout_q2")
      expect(event["properties"]).to include("holdoutId" => "holdout_q2",
                                             "holdoutKey" => "q2-2026-holdout")
      client.close
    end

    it "sends nothing when events are disabled" do
      client = bootstrapped(events: false)
      client.get_bool_flag("checkout-v2", default_value: false, context: context)
      client.flush

      expect(exposures_in(posts)).to be_empty
      client.close
    end
  end

  describe "#track" do
    it "queues a metric event with revenue and value kept apart" do
      client = bootstrapped
      client.track("purchase_completed", context: context, revenue: 49.99, value: 2)
      client.flush

      metric = posts.find { |r| r[:url].end_with?("/v1/collect/metric-batch") }
      expect(metric).not_to be_nil
      event = metric[:body]["metricEvents"].first
      expect(event["eventName"]).to eq("purchase_completed")
      expect(event["visitorId"]).to eq("alice")
      expect(event["revenue"]).to eq(49.99)
      expect(event["value"]).to eq(2)
      expect(metric[:body]["sdkKey"]).to eq(sdk_key)
      client.close
    end

    it "says so rather than dropping the event silently before the SDK is ready" do
      allow(Avsb::Http).to receive(:get)
        .and_return(Avsb::Http::Response.new(404, "", nil, nil))
      client = build
      client.wait_for_ready(timeout: 2)
      client.track("purchase_completed", context: context)

      expect(logger).to have_received(:warn).with(/track.*was dropped.*not ready/m)
      client.close
    end
  end

  describe "#track_purchase" do
    it "sends the order immediately to the orders path" do
      client = bootstrapped
      client.track_purchase(context, { "orderId" => "ORD-1", "total" => 99.95 })

      order_request = posts.find { |r| r[:url].end_with?("/v1/collect/orders") }
      expect(order_request).not_to be_nil
      expect(order_request[:body]["orders"].first).to include(
        "orderId" => "ORD-1", "total" => 99.95, "visitorId" => "alice"
      )
      client.close
    end
  end

  describe "heartbeat" do
    it "posts the locked heartbeat body after a successful fetch" do
      client = build
      client.wait_for_ready(timeout: 2)

      heartbeat = posts.find { |r| r[:url].end_with?("/api/sdk/heartbeat") }
      expect(heartbeat).not_to be_nil
      expect(heartbeat[:body]).to eq({
        "sdkKey" => sdk_key, "sdkType" => "avsb-ruby", "sdkVersion" => Avsb::VERSION
      })
      client.close
    end

    it "does not send one when the datafile carries no heartbeat endpoint" do
      client = build(datafile: datafile.reject { |k, _| k == "heartbeatEndpoint" })
      expect(posts.select { |r| r[:url].include?("heartbeat") }).to be_empty
      client.close
    end

    it "sends at most one per interval, not one per refresh" do
      client = bootstrapped
      client.replace_datafile(datafile)
      client.replace_datafile(datafile)

      expect(posts.count { |r| r[:url].end_with?("/api/sdk/heartbeat") }).to eq(1)
      client.close
    end
  end

  describe "sticky bucketing" do
    it "is consulted before the evaluator and saved after an ab_test match" do
      spy = Avsb::TestUtils::SpyStickyBucketService.new
      client = bootstrapped(sticky_bucket_service: spy)

      first = client.get_bool_flag("checkout-v2", default_value: false, context: context)
      expect(first.source).to eq("rule")
      expect(spy.lookups.first).to eq({ user_id: "alice", flag_key: "checkout-v2" })
      expect(spy.saves.first[:assignment][:variation_id]).to eq("var_on")
      client.close
    end

    it "serves the stored assignment on the next evaluation" do
      spy = Avsb::TestUtils::SpyStickyBucketService.new(
        preset: { "alice:checkout-v2" => { variation_id: "var_off", rule_id: "rule_ab",
                                           rule_type: "ab_test", assigned_at: 1 } }
      )
      client = bootstrapped(sticky_bucket_service: spy)
      flag = client.get_bool_flag("checkout-v2", default_value: true, context: context)

      expect(flag.source).to eq("sticky")
      expect(flag.value).to be false
      expect(flag.variation_key).to eq("off")
      client.close
    end
  end

  describe "degraded serving" do
    it "flags itself degraded when a refresh fails while a datafile is in memory" do
      client = bootstrapped
      expect(client.degraded?).to be false

      # Drive the refresh path directly: the poll loop is off in these tests.
      client.send(:handle_refresh_error, RuntimeError.new("HTTP 500"))

      expect(client.degraded?).to be true
      client.close
    end
  end

  describe "#close" do
    it "flushes queued events" do
      client = bootstrapped
      client.get_bool_flag("checkout-v2", default_value: false, context: context)
      expect(client.pending_event_count).to eq(1)

      client.close

      expect(exposures_in(posts).length).to eq(1)
      expect(client.pending_event_count).to eq(0)
    end

    it "is idempotent" do
      client = bootstrapped
      client.close
      expect { client.close }.not_to raise_error
    end
  end

  describe "#wait_for_ready" do
    it "returns nil when the timeout expires first" do
      allow(Avsb::Http).to receive(:get) do
        sleep 0.2
        Avsb::Http::Response.new(200, JSON.generate(datafile), nil, nil)
      end
      client = build
      expect(client.wait_for_ready(timeout: 0.01)).to be_nil
      client.wait_for_ready(timeout: 2)
      client.close
    end
  end
end
