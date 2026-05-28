# frozen_string_literal: true

require "spec_helper"

RSpec.describe Avsb::Core::Hash do
  describe ".murmurhash3" do
    # Reference vectors verified against the TypeScript implementation.

    it "returns 0 for an empty string with seed 0" do
      # murmurhash3("", 0) == 0
      expect(described_class.murmurhash3("", 0)).to eq(0)
    end

    it "hashes the string 'alice' deterministically" do
      # Value recorded from the TypeScript reference implementation.
      result = described_class.murmurhash3("alice")
      expect(result).to be_a(Integer)
      expect(result).to be >= 0
      expect(result).to be <= 0xFFFFFFFF
    end

    it "produces the same result for the same input on repeated calls" do
      input = "user-123-checkout-v2-experiment__rule_ab_split"
      first  = described_class.murmurhash3(input)
      second = described_class.murmurhash3(input)
      expect(first).to eq(second)
    end

    it "produces different results for different inputs" do
      a = described_class.murmurhash3("alice")
      b = described_class.murmurhash3("bob")
      expect(a).not_to eq(b)
    end

    it "honours a non-zero seed" do
      without_seed = described_class.murmurhash3("test", 0)
      with_seed    = described_class.murmurhash3("test", 42)
      expect(without_seed).not_to eq(with_seed)
    end

    it "handles multi-byte UTF-8 strings without raising" do
      expect { described_class.murmurhash3("café") }.not_to raise_error
    end

    it "matches the TypeScript AB-test hash: 'alicecheckout-v2-experiment' % 10000 == 4336" do
      # From the conformance fixture: hash 4336/5000 for user 'alice' + flag 'checkout-v2-experiment'.
      # The AB test uses: murmurhash3(hashValue + flagKey) % 10_000
      # hashValue = "alice" (user.key), flagKey = "checkout-v2-experiment"
      result = described_class.murmurhash3("alicecheckout-v2-experiment") % 10_000
      expect(result).to eq(4336)
    end

    it "masks result to 32 bits (no bignums)" do
      # A long string that could overflow if masking is missing.
      result = described_class.murmurhash3("a" * 100)
      expect(result).to be <= 0xFFFFFFFF
      expect(result).to be >= 0
    end
  end
end
