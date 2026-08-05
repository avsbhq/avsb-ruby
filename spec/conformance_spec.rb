# frozen_string_literal: true

require "spec_helper"
require "json"

# Conformance suite — runs every case in the conformance corpus manifest.
#
# For each case the spec:
#   1. Loads the datafile JSON referenced by the fixture.
#   2. Loads the context JSON.
#   3. Calls Core::Evaluator.evaluate_flag with the fixture's flagKey and defaultValue.
#   4. Asserts every field in the fixture's "expected" hash matches the result.
#
# FAIL-HARD RULE (conformance README): a missing manifest, an empty manifest,
# or a missing per-case file RAISES. This spec used to `pending` the whole
# suite when the manifest was absent and `next` past missing per-case files
# inside the loop, so the published avsb-ruby repo (where the monorepo-relative
# fixture path does not exist) reported green while running zero cases.
#
# Fixture resolution prefers the monorepo copy and falls back to the copy
# vendored into this gem, which is what the published repo carries.

FIXTURE_CANDIDATES = [
  # Monorepo: packages/avsb-ruby/spec -> packages/avsb-conformance/fixtures
  File.expand_path("../../avsb-conformance/fixtures", __dir__),
  # Published repo: vendored copy shipped with the gem.
  File.expand_path("vendor/avsb-conformance/fixtures", __dir__)
].freeze

FIXTURES_DIR = FIXTURE_CANDIDATES.find do |candidate|
  File.file?(File.join(candidate, "manifest.json"))
end

if FIXTURES_DIR.nil?
  raise <<~MESSAGE
    Conformance fixtures not found. Looked for manifest.json in:
      #{FIXTURE_CANDIDATES.join("\n  ")}
    In the monorepo, run `npm run generate` in packages/avsb-conformance.
    For this repo standalone, run `npm run vendor` there and commit spec/vendor.
  MESSAGE
end

def load_conformance_fixture(relative_path, case_name)
  path = File.join(FIXTURES_DIR, relative_path)
  unless File.file?(path)
    raise "Conformance fixture missing: #{path} (case #{case_name}). " \
          "Run `npm run generate` in packages/avsb-conformance."
  end
  JSON.parse(File.read(path))
end

RSpec.describe "Conformance suite" do
  manifest = JSON.parse(File.read(File.join(FIXTURES_DIR, "manifest.json")))
  manifest_cases = manifest["cases"]

  if !manifest_cases.is_a?(Array) || manifest_cases.empty?
    raise "Conformance manifest at #{FIXTURES_DIR} lists no cases. " \
          "An empty corpus guarantees nothing."
  end

  declared_count = manifest["caseCount"]
  if !declared_count.nil? && declared_count != manifest_cases.length
    raise "Conformance manifest says caseCount=#{declared_count} but carries " \
          "#{manifest_cases.length} cases, so it was hand-edited."
  end

  it "runs every case the manifest declares" do
    expect(manifest_cases.length).to eq(declared_count) unless declared_count.nil?
    expect(manifest_cases).not_to be_empty
  end

  it "has no fixture files the manifest does not name" do
    named = manifest_cases.map { |c| "#{c['case']}.json" }
    on_disk = Dir.glob(File.join(FIXTURES_DIR, "expected", "*.json")).map { |p| File.basename(p) }
    expect(on_disk - named).to eq([])
  end

  manifest_cases.each do |test_case|
    case_name = test_case["case"]
    expected_fixture = load_conformance_fixture(test_case["expected"], case_name)

    if expected_fixture["case"] != case_name
      raise "Fixture #{test_case['expected']} declares case " \
            "#{expected_fixture['case'].inspect} but the manifest names it " \
            "#{case_name.inspect}."
    end

    datafile = load_conformance_fixture(expected_fixture["datafile"], case_name)
    context = load_conformance_fixture(expected_fixture["context"], case_name)
    flag_key = expected_fixture["flagKey"]
    default_value = expected_fixture["defaultValue"]
    expected = expected_fixture["expected"]

    describe case_name do
      # Reasons are part of the corpus, so the harness always collects them.
      let(:reasons) { [] }

      subject(:result) do
        Avsb::Core::Evaluator.evaluate_flag(
          flag_key, default_value, context, datafile, reasons: reasons
        )
      end

      it "matches expected.value" do
        expect(result[:value]).to eq(expected["value"])
      end

      it "matches expected.variationKey" do
        expect(result[:variation_key]).to eq(expected["variationKey"])
      end

      it "matches expected.source" do
        expect(result[:source]).to eq(expected["source"])
      end

      it "matches expected.ruleId" do
        expect(result[:rule_id]).to eq(expected["ruleId"])
      end

      it "matches expected.ruleType" do
        expect(result[:rule_type]).to eq(expected["ruleType"])
      end

      # Exact, ordered comparison: the decision trail is part of the contract,
      # not a debug nicety (spec section 1.4).
      it "matches expected.reasons exactly and in order" do
        expect(result[:reasons]).to eq(expected["reasons"])
      end
    end
  end
end
