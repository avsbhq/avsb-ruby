# frozen_string_literal: true

require "spec_helper"

RSpec.describe Avsb::Core::JsValue do
  describe ".number_to_s" do
    # The conformance corpus records reason text exactly, including threshold
    # numbers. Ruby's Float#to_s would print "1000.0" where the reference
    # prints "1000", which fails every boundary fixture on a formatting
    # difference rather than a math one.
    it "prints an integral float without a decimal point" do
      expect(described_class.number_to_s(0.1 * 10_000)).to eq("1000")
      expect(described_class.number_to_s(0.333 * 10_000)).to eq("3330")
      expect(described_class.number_to_s(5000.0)).to eq("5000")
    end

    it "keeps the fraction on a fractional threshold" do
      expect(described_class.number_to_s(0.12345 * 10_000)).to eq("1234.5")
      expect(described_class.number_to_s(6234.5)).to eq("6234.5")
    end

    it "prints integers as themselves" do
      expect(described_class.number_to_s(10_000)).to eq("10000")
    end

    it "prints NaN and infinities the way JavaScript does" do
      expect(described_class.number_to_s(Float::NAN)).to eq("NaN")
      expect(described_class.number_to_s(Float::INFINITY)).to eq("Infinity")
      expect(described_class.number_to_s(-Float::INFINITY)).to eq("-Infinity")
    end
  end

  describe ".number" do
    it "parses numeric strings" do
      expect(described_class.number("12")).to eq(12.0)
      expect(described_class.number(" 12.5 ")).to eq(12.5)
      expect(described_class.number("-3")).to eq(-3.0)
      expect(described_class.number("1e3")).to eq(1000.0)
    end

    it "treats a non-numeric string as not-a-number instead of zero" do
      # Ruby's "abc".to_f is 0.0, which would make `greater_than -1` match a
      # text attribute. JavaScript's Number("abc") is NaN and every comparison
      # against it is false.
      expect(described_class.number("abc")).to be_nil
      expect(described_class.number("12abc")).to be_nil
    end

    it "treats empty and whitespace strings as zero, as JavaScript does" do
      expect(described_class.number("")).to eq(0.0)
      expect(described_class.number("   ")).to eq(0.0)
    end

    it "coerces booleans" do
      expect(described_class.number(true)).to eq(1.0)
      expect(described_class.number(false)).to eq(0.0)
    end

    it "treats a missing value and a NaN float as not-a-number" do
      expect(described_class.number(nil)).to be_nil
      expect(described_class.number(Float::NAN)).to be_nil
    end

    it "treats containers as not-a-number" do
      expect(described_class.number([])).to be_nil
      expect(described_class.number({})).to be_nil
    end
  end

  describe ".number_pair" do
    it "returns both sides when both are numeric" do
      expect(described_class.number_pair(25, "18")).to eq([25.0, 18.0])
    end

    it "returns nil when either side is not a number" do
      expect(described_class.number_pair("abc", "18")).to be_nil
      expect(described_class.number_pair(25, "eighteen")).to be_nil
      expect(described_class.number_pair(nil, "0")).to be_nil
    end
  end
end
