# frozen_string_literal: true

require "spec_helper"
require "json"

# The conformance allocation family: targeted delivery rollouts (N1-1).
#
# Six generated fixtures, one rollout rule each (5, 30 and 50 percent, a
# fractional 0.12345 boundary, 100 percent and no allocation), each with 200
# contexts whose outcomes the TypeScript reference recorded. Every one of the
# 1,200 evaluations is replayed, reasons included, so a visitor is inside or
# outside a rollout identically here and in every other SDK.
#
# FAIL-HARD RULE (conformance README, "The allocation family"): a missing
# manifest, an empty or miscounted fixture list, a missing file, a case that
# differs from its manifest entry, a fixture with the wrong number of
# evaluations, or a JSON file the manifest does not name all RAISE. Resolution
# prefers the monorepo copy and falls back to the copy vendored into this gem,
# exactly as conformance_spec.rb does.

ALLOCATION_FIXTURE_CANDIDATES = [
  # Monorepo: packages/avsb-ruby/spec -> packages/avsb-conformance/fixtures
  File.expand_path("../../avsb-conformance/fixtures/allocation", __dir__),
  # Published repo: vendored copy shipped with the gem.
  File.expand_path("vendor/avsb-conformance/fixtures/allocation", __dir__)
].freeze

ALLOCATION_DIR = ALLOCATION_FIXTURE_CANDIDATES.find do |candidate|
  File.file?(File.join(candidate, "manifest.json"))
end

if ALLOCATION_DIR.nil?
  raise <<~MESSAGE
    Conformance allocation fixtures not found. Looked for manifest.json in:
      #{ALLOCATION_FIXTURE_CANDIDATES.join("\n  ")}
    Run `npm run generate` then `npm run vendor` in packages/avsb-conformance,
    and commit spec/vendor.
  MESSAGE
end

RSpec.describe "Conformance allocation family" do
  manifest = JSON.parse(File.read(File.join(ALLOCATION_DIR, "manifest.json")))
  entries = manifest["fixtures"]
  per_fixture = manifest["contextsPerFixture"]

  if !entries.is_a?(Array) || entries.empty?
    raise "The allocation manifest at #{ALLOCATION_DIR} lists no fixtures. " \
          "An empty family guarantees nothing."
  end
  if manifest["fixtureCount"] != entries.length
    raise "The allocation manifest says fixtureCount=#{manifest['fixtureCount']} " \
          "but lists #{entries.length} fixtures, so it was hand-edited."
  end
  unless per_fixture.is_a?(Integer) && per_fixture.positive?
    raise "The allocation manifest declares no contextsPerFixture."
  end

  fixtures = entries.map do |entry|
    path = File.join(ALLOCATION_DIR, entry["file"])
    unless File.file?(path)
      raise "Allocation fixture missing: #{path}. Run `npm run generate` then " \
            "`npm run vendor` in packages/avsb-conformance."
    end
    fixture = JSON.parse(File.read(path))
    if fixture["case"] != entry["case"]
      raise "Allocation fixture #{entry['file']} declares case " \
            "#{fixture['case'].inspect} but the manifest names it #{entry['case'].inspect}."
    end
    evaluations = fixture["evaluations"]
    unless evaluations.is_a?(Array) && evaluations.length == per_fixture
      raise "Allocation fixture #{entry['file']} does not carry #{per_fixture} evaluations."
    end
    fixture
  end

  # One entry per evaluation: nil when it matches the reference, else the drift.
  replay = lambda do |fixture|
    fixture["evaluations"].map do |evaluation|
      # Reasons are part of the contract, so the harness always collects them.
      result = Avsb::Core::Evaluator.evaluate_flag(
        fixture["flagKey"], fixture["defaultValue"], evaluation["context"],
        fixture["datafile"], reasons: []
      )
      observed = {
        "value" => result[:value],
        "variationKey" => result[:variation_key],
        "source" => result[:source],
        "ruleId" => result[:rule_id],
        "ruleType" => result[:rule_type],
        "reasons" => result[:reasons]
      }
      observed == evaluation["expected"] ? nil : "#{evaluation['context']['key']}: #{observed.inspect}"
    end
  end

  fixtures.each do |fixture|
    it "reproduces all #{per_fixture} evaluations of #{fixture['case']}" do
      outcomes = replay.call(fixture)
      expect(outcomes.length).to eq(per_fixture)
      expect(outcomes.compact).to eq([])
    end
  end

  it "ran the whole family, so nothing can pass by running nothing" do
    total = fixtures.sum { |fixture| replay.call(fixture).length }
    expect(total).to eq(manifest["fixtureCount"] * per_fixture)
    expect(total).to eq(1200)
  end

  it "carries the six rollout levels" do
    expect(entries.map { |entry| entry["case"] }).to eq(
      %w[
        targeted_delivery_allocation_0.05
        targeted_delivery_allocation_0.3
        targeted_delivery_allocation_0.5
        targeted_delivery_allocation_fractional_boundary
        targeted_delivery_allocation_1.0
        targeted_delivery_allocation_null
      ]
    )
  end

  it "has no allocation fixture the manifest does not name" do
    named = entries.map { |entry| entry["file"] }
    on_disk = Dir.glob(File.join(ALLOCATION_DIR, "*.json"))
                 .map { |path| File.basename(path) }
                 .reject { |name| name == "manifest.json" }
    expect(on_disk - named).to eq([])
  end

  it "puts the fractional fixture's searched boundary keys first" do
    fractional = fixtures.find do |fixture|
      fixture["case"] == "targeted_delivery_allocation_fractional_boundary"
    end
    probes = fractional["probes"]
    first_two = fractional["evaluations"].first(2)

    expect(probes.map { |probe| probe["bucket"] }).to eq([1234, 1235])
    expect(first_two.map { |e| e["context"]["key"] }).to eq(probes.map { |probe| probe["resolvedKey"] })
    # Bucket 1234 is inside the 1234.5 threshold; a port that floors it says no.
    expect(first_two.map { |e| e["expected"]["source"] }).to eq(%w[rule default])
  end
end
