# frozen_string_literal: true

require "spec_helper"

# Load OpenFeature SDK if available — skip gracefully if not installed.
OPENFEATURE_AVAILABLE =
  begin
    require "open_feature/sdk"
    true
  rescue LoadError
    false
  end

RSpec.describe Avsb::OpenFeatureProvider do
  let(:flag_result) do
    Avsb::Flag.new(
      value:         true,
      variation_key: "on",
      source:        "rule",
      rule_id:       "r1",
      rule_type:     "targeted_delivery",
      reasons:       [],
    )
  end

  let(:fake_client) do
    double("Avsb::Server").tap do |d|
      allow(d).to receive(:get_bool_flag).and_return(flag_result)
      allow(d).to receive(:get_string_flag).and_return(
        Avsb::Flag.new(value: "hello", variation_key: "greet", source: "rule",
                       rule_id: nil, rule_type: nil, reasons: [])
      )
      allow(d).to receive(:get_number_flag).and_return(
        Avsb::Flag.new(value: 42.0, variation_key: "v1", source: "default",
                       rule_id: nil, rule_type: nil, reasons: [])
      )
      allow(d).to receive(:get_json_flag).and_return(
        Avsb::Flag.new(value: { "a" => 1 }, variation_key: "obj", source: "rule",
                       rule_id: nil, rule_type: nil, reasons: [])
      )
    end
  end

  subject(:provider) { described_class.new(fake_client) }

  describe "#metadata" do
    it "returns a hash with name key" do
      expect(provider.metadata[:name]).to eq("AvsB")
    end
  end

  describe "#resolve_boolean_value" do
    it "returns the flag value" do
      result = provider.resolve_boolean_value("my-flag", false)
      expect(result[:value]).to be true
    end

    it "maps rule source to TARGETING_MATCH reason" do
      result = provider.resolve_boolean_value("my-flag", false)
      expect(result[:reason]).to eq("TARGETING_MATCH")
    end

    it "passes the evaluation context to the client" do
      eval_ctx = { "targetingKey" => "alice", "plan" => "pro" }
      expect(fake_client).to receive(:get_bool_flag).with(
        "my-flag",
        default_value: false,
        context: hash_including("key" => "alice", "plan" => "pro"),
      ).and_return(flag_result)
      provider.resolve_boolean_value("my-flag", false, eval_ctx)
    end
  end

  describe "#resolve_string_value" do
    it "returns the string flag value" do
      result = provider.resolve_string_value("greet-flag", "default")
      expect(result[:value]).to eq("hello")
    end
  end

  describe "#resolve_number_value" do
    it "returns the numeric flag value" do
      result = provider.resolve_number_value("num-flag", 0)
      expect(result[:value]).to eq(42.0)
    end

    it "maps default source to DEFAULT reason" do
      result = provider.resolve_number_value("num-flag", 0)
      expect(result[:reason]).to eq("DEFAULT")
    end
  end

  describe "#resolve_object_value" do
    it "returns the JSON flag value" do
      result = provider.resolve_object_value("json-flag", {})
      expect(result[:value]).to eq({ "a" => 1 })
    end
  end

  if OPENFEATURE_AVAILABLE
    it "can be registered with the OpenFeature SDK without raising" do
      expect { OpenFeature::SDK.configure { |c| c.set_provider(provider) } }.not_to raise_error
    end
  else
    it "loads without error when openfeature-sdk is not installed" do
      expect { Avsb::OpenFeatureProvider }.not_to raise_error
    end
  end
end
