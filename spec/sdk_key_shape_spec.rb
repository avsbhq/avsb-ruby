# frozen_string_literal: true

require "spec_helper"

RSpec.describe Avsb::SdkKeyShape do
  describe ".valid?" do
    it "accepts a real key" do
      expect(described_class.valid?("sdk_production_ttqm0eaj4vth1krcb2xn")).to be true
    end

    it "accepts an environment key containing underscores" do
      expect(described_class.valid?("sdk_staging_eu_ttqm0eaj4vth1krcb2xn")).to be true
    end

    it "rejects the values people actually paste by mistake" do
      expect(described_class.valid?("")).to be false
      expect(described_class.valid?("nonsense")).to be false
      expect(described_class.valid?("sdk_production_abc")).to be false
      expect(described_class.valid?("avsb_pat_abcdefghijklmnop")).to be false
      expect(described_class.valid?("https://app.avsb.cloud/projects/p_1/settings")).to be false
      expect(described_class.valid?(" sdk_production_ttqm0eaj4vth1krcb2xn ")).to be false
      expect(described_class.valid?(nil)).to be false
    end
  end

  describe ".message_for" do
    it "is nil for a valid key" do
      expect(described_class.message_for("sdk_production_ttqm0eaj4vth1krcb2xn")).to be_nil
    end

    it "names the URL mistake" do
      message = described_class.message_for("https://app.avsb.cloud/projects/p_1")
      expect(message).to include("looks like a URL")
      expect(message).to include("Settings")
    end

    it "names the token mistake" do
      expect(described_class.message_for("avsb_pat_abcdefghijklmnop"))
        .to include("looks like an API token")
    end

    it "names whitespace, the invisible one" do
      expect(described_class.message_for(" sdk_production_ttqm0eaj4vth1krcb2xn "))
        .to include("whitespace")
    end

    it "names a prefix that has never existed" do
      expect(described_class.message_for("sdk-abc123def456"))
        .to include("never existed")
    end

    it "says nothing was passed for an empty key" do
      expect(described_class.message_for("")).to include("no SDK key was passed at all")
    end

    it "explains that the SDK carries on regardless" do
      expect(described_class.message_for("nonsense"))
        .to include("keep going with the value you passed")
    end
  end

  describe ".describe" do
    it "keeps the environment half and redacts the id" do
      expect(described_class.describe("sdk_production_ttqm0eaj4vth1krcb2xn"))
        .to eq("sdk_producti...b2xn")
    end

    it "handles an empty key" do
      expect(described_class.describe(nil)).to eq("(empty)")
    end
  end
end
