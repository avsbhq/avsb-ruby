# frozen_string_literal: true

require "spec_helper"
require "json"

# Conformance suite — runs every case in packages/avsb-conformance/fixtures/manifest.json.
#
# For each case the spec:
#   1. Loads the datafile JSON referenced by the fixture.
#   2. Loads the context JSON.
#   3. Calls Core::Evaluator.evaluate_flag with the fixture's flagKey and defaultValue.
#   4. Asserts every field present in the fixture's "expected" hash matches the result.
#
# Fields absent from "expected" (e.g. "source" is absent for the holdout fixture) are
# intentionally not asserted — partial matching lets cases focus on what matters.

FIXTURES_DIR = File.expand_path("../../avsb-conformance/fixtures", __dir__)

RSpec.describe "Conformance suite" do
  manifest_path = File.join(FIXTURES_DIR, "manifest.json")

  unless File.exist?(manifest_path)
    pending "conformance fixtures not found at #{FIXTURES_DIR}"
    return
  end

  manifest = JSON.parse(File.read(manifest_path))

  manifest["cases"].each do |test_case|
    case_name = test_case["case"]
    expected_path = File.join(FIXTURES_DIR, test_case["expected"])

    next unless File.exist?(expected_path)

    expected_fixture = JSON.parse(File.read(expected_path))

    # Load datafile and context from paths declared in the expected fixture.
    datafile_path = File.join(FIXTURES_DIR, expected_fixture["datafile"])
    context_path  = File.join(FIXTURES_DIR, expected_fixture["context"])

    next unless File.exist?(datafile_path) && File.exist?(context_path)

    datafile       = JSON.parse(File.read(datafile_path))
    context        = JSON.parse(File.read(context_path))
    flag_key       = expected_fixture["flagKey"]
    default_value  = expected_fixture["defaultValue"]
    expected       = expected_fixture["expected"]

    describe case_name do
      subject(:result) do
        Avsb::Core::Evaluator.evaluate_flag(
          flag_key, default_value, context, datafile, reasons: []
        )
      end

      it "matches expected.value" do
        expect(result[:value]).to eq(expected["value"])
      end

      it "matches expected.variationKey" do
        expect(result[:variation_key]).to eq(expected["variationKey"])
      end

      if expected.key?("source")
        it "matches expected.source" do
          expect(result[:source]).to eq(expected["source"])
        end
      end

      if expected.key?("ruleId")
        it "matches expected.ruleId" do
          expect(result[:rule_id]).to eq(expected["ruleId"])
        end
      end

      if expected.key?("ruleType")
        it "matches expected.ruleType" do
          expect(result[:rule_type]).to eq(expected["ruleType"])
        end
      end

      if expected.key?("reasons")
        it "includes all expected reason strings" do
          expected["reasons"].each do |expected_reason|
            expect(result[:reasons]).to include(expected_reason),
              "expected reasons to include #{expected_reason.inspect}\ngot: #{result[:reasons].inspect}"
          end
        end
      end
    end
  end
end
