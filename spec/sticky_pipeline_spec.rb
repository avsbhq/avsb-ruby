# frozen_string_literal: true

require "spec_helper"

RSpec.describe Avsb::StickyPipeline do
  let(:logger) { instance_double(Avsb::Logger, debug: nil, info: nil, warn: nil, error: nil) }
  let(:service) { Avsb::TestUtils::SpyStickyBucketService.new(preset: preset) }
  let(:preset) { {} }

  let(:datafile) do
    {
      "flags" => [{
        "id" => "flag_1", "key" => "checkout-v2", "type" => "boolean", "enabled" => true,
        "defaultVariationId" => "var_off",
        "variations" => [
          { "id" => "var_off", "key" => "off", "value" => false },
          { "id" => "var_on",  "key" => "on",  "value" => true },
        ],
        "overrides" => [],
        "rules" => [{
          "id" => "rule_ab", "type" => "ab_test", "enabled" => true, "audienceIds" => [],
          "hashAttribute" => "user.key", "trafficAllocation" => 1,
          "variations" => [
            { "variationId" => "var_off", "percentage" => 0.5 },
            { "variationId" => "var_on", "percentage" => 0.5 },
          ],
        }],
      }],
    }
  end

  def pipeline(on_orphan: nil)
    described_class.new(service: service, logger: logger, on_orphan: on_orphan)
  end

  describe "#lookup" do
    context "with a stored assignment for a live variation" do
      let(:preset) do
        { "alice:checkout-v2" => { variation_id: "var_on", rule_id: "rule_ab",
                                   rule_type: "ab_test", assigned_at: 1 } }
      end

      it "returns the stored variation with source=sticky and does not consult the evaluator" do
        reasons = []
        result  = pipeline.lookup(datafile, "checkout-v2", "alice", reasons)

        expect(result[:source]).to eq("sticky")
        expect(result[:value]).to be true
        expect(result[:variation_key]).to eq("on")
        expect(result[:rule_id]).to eq("rule_ab")
        expect(result[:rule_type]).to eq("ab_test")
        expect(reasons).to eq(['matched sticky bucket assignment for userId="alice"'])
      end

      it "yields so the caller can record the exposure" do
        yielded = []
        pipeline.lookup(datafile, "checkout-v2", "alice", []) do |assignment, variation|
          yielded << [assignment[:rule_id], variation["id"]]
        end

        expect(yielded).to eq([["rule_ab", "var_on"]])
      end
    end

    it "reads a camel-cased store written against the cross-language contract" do
      camel = { "alice:checkout-v2" => { "variationId" => "var_on", "ruleId" => "rule_ab",
                                         "ruleType" => "ab_test", "assignedAt" => 1 } }
      spy = Avsb::TestUtils::SpyStickyBucketService.new(preset: camel)
      result = described_class.new(service: spy, logger: logger)
                             .lookup(datafile, "checkout-v2", "alice", [])

      expect(result[:variation_key]).to eq("on")
    end

    it "falls through on a miss" do
      expect(pipeline.lookup(datafile, "checkout-v2", "alice", [])).to be_nil
    end

    context "when the stored variation was deleted from the flag" do
      let(:preset) do
        { "alice:checkout-v2" => { variation_id: "var_deleted", rule_id: "rule_ab",
                                   rule_type: "ab_test", assigned_at: 1 } }
      end

      it "treats it as a miss, because serving a variation that is gone is impossible" do
        reasons = []
        expect(pipeline.lookup(datafile, "checkout-v2", "alice", reasons)).to be_nil
        expect(reasons).to be_empty
      end
    end

    context "when the stored rule no longer serves that variation" do
      let(:preset) do
        { "alice:checkout-v2" => { variation_id: "var_on", rule_id: "rule_deleted",
                                   rule_type: "ab_test", assigned_at: 1 } }
      end

      it "still serves the stored value but suppresses the exposure" do
        exposures = []
        result = pipeline.lookup(datafile, "checkout-v2", "alice", []) do |_a, _v|
          exposures << :fired
        end

        expect(result[:value]).to be true
        expect(exposures).to be_empty
        expect(logger).to have_received(:warn).with(/no longer serves variation/)
      end

      it "reports the orphan to the callback" do
        seen = []
        pipeline(on_orphan: ->(payload) { seen << payload })
          .lookup(datafile, "checkout-v2", "alice", [])

        expect(seen.first[:flag_key]).to eq("checkout-v2")
        expect(seen.first[:user_id]).to eq("alice")
        expect(seen.first[:assignment][:rule_id]).to eq("rule_deleted")
      end
    end

    it "survives a store that raises" do
      broken = double("store")
      allow(broken).to receive(:lookup).and_raise(StandardError, "redis down")
      result = described_class.new(service: broken, logger: logger)
                             .lookup(datafile, "checkout-v2", "alice", [])

      expect(result).to be_nil
      expect(logger).to have_received(:warn).with(/sticky lookup failed.*redis down/)
    end

    it "does nothing at all when no service is configured" do
      expect(described_class.new(service: nil, logger: logger)
                            .lookup(datafile, "checkout-v2", "alice", [])).to be_nil
    end
  end

  describe "#save" do
    def result_for(source:, rule_type:, variation_key: "on", rule_id: "rule_ab")
      { value: true, variation_key: variation_key, source: source, rule_id: rule_id,
        rule_type: rule_type, flag_key: "checkout-v2", reasons: [] }
    end

    it "saves the variation ID, never its key" do
      pipeline.save(datafile, "checkout-v2", "alice",
                    result_for(source: "rule", rule_type: "ab_test"))

      saved = service.saves.first
      expect(saved[:user_id]).to eq("alice")
      expect(saved[:flag_key]).to eq("checkout-v2")
      expect(saved[:assignment][:variation_id]).to eq("var_on")
      expect(saved[:assignment][:rule_id]).to eq("rule_ab")
      expect(saved[:assignment][:rule_type]).to eq("ab_test")
      expect(saved[:assignment][:assigned_at]).to be_a(Integer)
    end

    it "does not save a targeted_delivery, which is a rollout and not an assignment" do
      pipeline.save(datafile, "checkout-v2", "alice",
                    result_for(source: "rule", rule_type: "targeted_delivery"))
      expect(service.saves).to be_empty
    end

    it "does not save a holdout" do
      pipeline.save(datafile, "checkout-v2", "alice",
                    result_for(source: "holdout", rule_type: "holdout"))
      expect(service.saves).to be_empty
    end

    it "does not save a default" do
      pipeline.save(datafile, "checkout-v2", "alice",
                    result_for(source: "default", rule_type: nil))
      expect(service.saves).to be_empty
    end

    it "does not save an override" do
      pipeline.save(datafile, "checkout-v2", "alice",
                    result_for(source: "datafileOverride", rule_type: nil))
      expect(service.saves).to be_empty
    end

    it "swallows a store failure with a warning rather than failing the evaluation" do
      broken = double("store")
      allow(broken).to receive(:save).and_raise(StandardError, "redis down")

      expect do
        described_class.new(service: broken, logger: logger)
                       .save(datafile, "checkout-v2", "alice",
                             result_for(source: "rule", rule_type: "ab_test"))
      end.not_to raise_error
      expect(logger).to have_received(:warn).with(/sticky save failed.*redis down/)
    end
  end
end
