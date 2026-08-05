# frozen_string_literal: true

require "spec_helper"
require "json"

# The tracker owns the wire contract. Field names here are frozen vocabulary
# (packages/avsb-conformance/fixtures/wire/manifest.json): the ingestion worker
# validates these exact names and the dashboard reads the columns they land in,
# so a renamed field is data that looks delivered and is gone.
RSpec.describe Avsb::Tracker do
  let(:sent) { [] }

  # auto_flush: false keeps every flush on the example's thread.
  def build(logger: Avsb::NoopLogger.new, **overrides)
    described_class.new(
      sdk_key: "sdk_production_trackerfixture01",
      collect_endpoint: "https://ingest.avsb.cloud",
      logger: logger,
      auto_flush: false,
      **overrides
    )
  end

  def exposure(visitor: "user_42")
    {
      "visitorId" => visitor, "experimentId" => "rule_ab", "variationId" => "var_treatment",
      "eventName" => "flag_exposure", "revenue" => nil, "timestamp" => 1_780_000_000_000,
      "pageUrl" => "", "properties" => { "flagKey" => "checkout-v2", "flagId" => "flag_1" }
    }
  end

  before do
    allow(Avsb::Http).to receive(:post_json) do |url, body, **_kwargs|
      sent << { url: url, body: JSON.parse(body) }
      Avsb::Http::Response.new(202, "", nil, nil)
    end
  end

  describe "exposure batches" do
    it "posts to the locked batch path with sdkKey in the envelope" do
      tracker = build
      tracker.queue(exposure)
      tracker.flush

      expect(sent.length).to eq(1)
      expect(sent.first[:url]).to eq("https://ingest.avsb.cloud/v1/collect/batch")
      expect(sent.first[:body]["sdkKey"]).to eq("sdk_production_trackerfixture01")
      expect(sent.first[:body]["events"].length).to eq(1)
    end

    it "sends every required field, with the required names" do
      tracker = build
      tracker.queue(exposure)
      tracker.flush

      event = sent.first[:body]["events"].first
      expect(event.keys).to include(
        "eventId", "visitorId", "experimentId", "variationId", "eventName",
        "revenue", "timestamp", "pageUrl"
      )
      expect(event["eventName"]).to eq("flag_exposure")
      expect(event["revenue"]).to be_nil
      expect(event["pageUrl"]).to eq("")
    end

    it "stamps an eventId once, at enqueue, so a retried batch is deduplicable" do
      tracker = build
      tracker.queue(exposure)
      first_id = nil

      # First attempt fails, second succeeds: both carry the same id.
      call_count = 0
      allow(Avsb::Http).to receive(:post_json) do |url, body, **_kwargs|
        call_count += 1
        parsed = JSON.parse(body)
        first_id ||= parsed["events"].first["eventId"]
        expect(parsed["events"].first["eventId"]).to eq(first_id)
        Avsb::Http::Response.new(call_count == 1 ? 500 : 202, "", nil, nil)
      end
      allow(tracker).to receive(:sleep)

      tracker.flush
      expect(call_count).to eq(2)
      expect(first_id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "keeps a caller-supplied eventId" do
      tracker = build
      tracker.queue(exposure.merge("eventId" => "supplied-id"))
      tracker.flush

      expect(sent.first[:body]["events"].first["eventId"]).to eq("supplied-id")
    end

    it "splits a flush into batch_size chunks" do
      tracker = build(batch_size: 2)
      4.times { |i| tracker.queue(exposure(visitor: "u#{i}")) }
      tracker.flush

      expect(sent.length).to eq(2)
      expect(sent.map { |req| req[:body]["events"].length }).to eq([2, 2])
    end
  end

  describe "metric batches" do
    it "posts to the metric-batch path under the metricEvents key" do
      tracker = build
      tracker.queue_metric({
                             "visitorId" => "user_42", "eventName" => "signup_completed",
                             "revenue" => nil, "value" => 1,
                             "timestamp" => 1_780_000_000_000, "pageUrl" => ""
                           })
      tracker.flush

      expect(sent.first[:url]).to eq("https://ingest.avsb.cloud/v1/collect/metric-batch")
      expect(sent.first[:body]["metricEvents"].first["eventName"]).to eq("signup_completed")
    end
  end

  describe "orders" do
    it "sends immediately, without waiting for a flush" do
      tracker = build
      result = tracker.track_purchase("user_42", { "orderId" => "ORD-1", "total" => 99.95 })

      expect(result).to be true
      expect(sent.first[:url]).to eq("https://ingest.avsb.cloud/v1/collect/orders")
      order = sent.first[:body]["orders"].first
      expect(order["orderId"]).to eq("ORD-1")
      expect(order["total"]).to eq(99.95)
      expect(order["visitorId"]).to eq("user_42")
      expect(order["eventId"]).to match(/\A[0-9a-f-]{36}\z/)
      expect(order["pageUrl"]).to eq("")
    end
  end

  describe "bounded queues" do
    it "drops the oldest events and says so" do
      loud = instance_double(Avsb::Logger, debug: nil, info: nil, warn: nil, error: nil)
      tracker = build(max_queue_size: 2, batch_size: 100, logger: loud)

      3.times { |i| tracker.queue(exposure(visitor: "u#{i}")) }
      tracker.flush

      expect(loud).to have_received(:warn).with(/queue full \(2\), dropped 1 oldest/)
      visitors = sent.first[:body]["events"].map { |e| e["visitorId"] }
      expect(visitors).to eq(%w[u1 u2])
    end
  end

  describe "retry and backoff" do
    it "gives up after retry_attempts and logs a reproduction curl" do
      loud = instance_double(Avsb::Logger, debug: nil, info: nil, warn: nil, error: nil)
      tracker = build(retry_attempts: 2, logger: loud)
      allow(tracker).to receive(:sleep)
      allow(Avsb::Http).to receive(:post_json)
        .and_return(Avsb::Http::Response.new(500, "", nil, nil))

      tracker.queue(exposure)
      tracker.flush

      expect(Avsb::Http).to have_received(:post_json).exactly(3).times
      expect(loud).to have_received(:error).with(/after 2 retries.*curl -i -X POST/m)
    end

    it "honours Retry-After for the next attempt" do
      tracker = build(retry_attempts: 1)
      delays = []
      allow(tracker).to receive(:sleep) { |seconds| delays << seconds }
      responses = [
        Avsb::Http::Response.new(429, "", nil, "7"),
        Avsb::Http::Response.new(202, "", nil, nil),
      ]
      allow(Avsb::Http).to receive(:post_json) { responses.shift }

      tracker.queue(exposure)
      tracker.flush

      expect(delays).to eq([7.0])
    end
  end

  describe "close" do
    it "flushes what is queued" do
      tracker = build
      tracker.queue(exposure)
      expect(tracker.pending_count).to eq(1)

      tracker.close

      expect(sent.length).to eq(1)
      expect(tracker.pending_count).to eq(0)
    end

    it "drops events queued after close instead of buffering them forever" do
      tracker = build
      tracker.close
      tracker.queue(exposure)

      expect(tracker.pending_count).to eq(0)
    end
  end

  describe "update_collect_endpoint" do
    it "sends to the new origin after a datafile refresh moves it" do
      tracker = build
      tracker.update_collect_endpoint("https://events.customer.test")
      tracker.queue(exposure)
      tracker.flush

      expect(sent.first[:url]).to eq("https://events.customer.test/v1/collect/batch")
    end
  end
end
