# frozen_string_literal: true

require "spec_helper"
require "json"

# The semantics family of the conformance corpus, asserted directly.
#
# These rules cannot be expressed as a datafile plus a context, so they are
# hand-authored in fixtures/semantics/manifest.json and every SDK asserts
# against them: what enabled? and exists? answer, which source spellings are
# legal, and what not_ready means.
#
# Reading the manifest rather than restating it is deliberate. A test that
# copies the table can drift from it; this one fails the moment the contract
# moves.

SEMANTICS_FIXTURE_CANDIDATES = [
  File.expand_path("../../avsb-conformance/fixtures/semantics/manifest.json", __dir__),
  File.expand_path("vendor/avsb-conformance/fixtures/semantics/manifest.json", __dir__)
].freeze

SEMANTICS_MANIFEST_PATH = SEMANTICS_FIXTURE_CANDIDATES.find { |path| File.file?(path) }

if SEMANTICS_MANIFEST_PATH.nil?
  raise <<~MESSAGE
    Semantics manifest not found. Looked in:
      #{SEMANTICS_FIXTURE_CANDIDATES.join("\n  ")}
    In the monorepo, run `npm run generate` in packages/avsb-conformance.
    For this repo standalone, run `npm run vendor` there and commit spec/vendor.
  MESSAGE
end

RSpec.describe "Evaluation semantics contract" do
  manifest = JSON.parse(File.read(SEMANTICS_MANIFEST_PATH))

  def flag_with(source:, value:)
    Avsb::Flag.new(
      value: value, variation_key: nil, source: source,
      rule_id: nil, rule_type: nil, reasons: []
    )
  end

  describe "source vocabulary" do
    it "declares every public source the manifest lists" do
      expect(Avsb::Core::EvaluationSource::ALL.sort).to eq(manifest["sources"]["public"].sort)
    end

    it "treats exactly the manifest's decided sources as decisions" do
      expect(Avsb::Core::EvaluationSource::DECIDED.sort)
        .to eq(manifest["sources"]["decided"].sort)
    end

    it "declares no banned spelling" do
      banned = manifest["sources"]["banned"]
      expect(Avsb::Core::EvaluationSource::ALL & banned).to eq([])
    end
  end

  describe "JavaScript truthiness, not Ruby's" do
    manifest["truthiness"]["falsy"].each do |row|
      it "treats #{row["value"].inspect} as falsy (#{row["why"]})" do
        expect(Avsb::Core::JsValue.truthy?(row["value"])).to be false
      end
    end

    manifest["truthiness"]["truthy"].each do |row|
      it "treats #{row["value"].inspect} as truthy (#{row["why"]})" do
        expect(Avsb::Core::JsValue.truthy?(row["value"])).to be true
      end
    end

    it "treats NaN as falsy, which no fixture row can express in JSON" do
      expect(Avsb::Core::JsValue.truthy?(Float::NAN)).to be false
    end

    it "treats -0.0 as falsy" do
      expect(Avsb::Core::JsValue.truthy?(-0.0)).to be false
    end
  end

  describe "enabled?" do
    manifest["isEnabled"]["cases"].each do |row|
      it "#{row["case"]}: source=#{row["source"]} value=#{row["value"].inspect} " \
         "is #{row["expected"]}" do
        flag = flag_with(source: row["source"], value: row["value"])
        expect(flag.enabled?).to be(row["expected"])
      end
    end
  end

  describe "exists?" do
    manifest["exists"]["cases"].each do |row|
      it "#{row["case"]}: source=#{row["source"]} is #{row["expected"]}" do
        flag = flag_with(source: row["source"], value: true)
        expect(flag.exists?).to be(row["expected"])
      end
    end
  end

  describe "not_ready" do
    # wait_for_ready keeps the init thread inside the example, so the stub is
    # still installed when the fetch runs and no test ever touches the network.
    let(:client) do
      Avsb::Server.new(sdk_key: "sdk_production_notreadyfixture01", polling_interval: nil,
                       logger: Avsb::NoopLogger.new).tap { |c| c.wait_for_ready(timeout: 2) }
    end

    before do
      # No datafile, and the fetch never lands, so every evaluation is the
      # not-ready path.
      allow(Avsb::Http).to receive(:get).and_return(
        Avsb::Http::Response.new(0, "", "Errno::ECONNREFUSED: connection refused", nil)
      )
    end

    after { client.close }

    it "returns the caller's default with its type intact" do
      flag = client.get_number_flag("anything", default_value: 42.5)
      expect(flag.value).to eq(42.5)
      expect(flag.value).to be_a(Float)
    end

    it "reports the manifest's expected envelope" do
      flag = client.get_bool_flag("anything", default_value: true)
      expected = manifest["notReady"]["expected"]
      expect(flag.source).to eq(expected["source"])
      expect(flag.variation_key).to be_nil
      expect(flag.rule_id).to be_nil
      expect(flag.rule_type).to be_nil
      expect(flag.enabled?).to be false
      expect(flag.exists?).to be false
    end

    it "names the state in the reason rather than claiming the flag is missing" do
      flag = client.get_bool_flag("anything", default_value: false)
      expect(flag.reasons.length).to eq(1)
      expect(flag.reasons.first).to match(/not ready/i)
      expect(flag.reasons.first).not_to match(/not found/i)
    end
  end
end
