# frozen_string_literal: true

require "spec_helper"

RSpec.describe Avsb::Backoff do
  # A fixed source of randomness so the curve can be asserted exactly. 0.5
  # means "no jitter", because the jitter term is (rand * 2 - 1).
  let(:no_jitter)  { double("random", rand: 0.5) }
  let(:max_jitter) { double("random", rand: 1.0) }
  let(:min_jitter) { double("random", rand: 0.0) }

  describe ".next_backoff" do
    it "climbs 1s, 2s, 4s, 8s from the first retry" do
      state = nil
      delays = 4.times.map do
        state = described_class.next_backoff(state, random: no_jitter)
        state.delay
      end

      expect(delays).to eq([1.0, 2.0, 4.0, 8.0])
      expect(state.attempt).to eq(4)
    end

    it "caps at 60 seconds" do
      state = described_class::State.new(20, 60.0)
      expect(described_class.next_backoff(state, random: no_jitter).delay).to eq(60.0)
    end

    it "spreads retries by plus or minus 20 percent" do
      high = described_class.next_backoff(described_class::State.new(3, 4.0), random: max_jitter)
      low  = described_class.next_backoff(described_class::State.new(3, 4.0), random: min_jitter)

      expect(high.delay).to be_within(0.0001).of(9.6)  # 8 + 20 percent
      expect(low.delay).to be_within(0.0001).of(6.4)   # 8 - 20 percent
    end

    it "never waits less than the floor" do
      # Attempt 1 with maximum negative jitter is 0.8s, still above the floor;
      # the floor exists so a future shorter base cannot produce a busy loop.
      state = described_class.next_backoff(nil, random: min_jitter)
      expect(state.delay).to be >= described_class::MIN_DELAY
    end

    it "honours Retry-After for that attempt and still climbs the counter" do
      first  = described_class.next_backoff(nil, retry_after: 7, random: no_jitter)
      second = described_class.next_backoff(first, random: no_jitter)

      expect(first.delay).to eq(7.0)
      expect(first.attempt).to eq(1)
      expect(second.delay).to eq(2.0)
    end

    it "ignores a non-positive Retry-After" do
      state = described_class.next_backoff(nil, retry_after: 0, random: no_jitter)
      expect(state.delay).to eq(1.0)
    end
  end

  describe ".parse_retry_after" do
    it "parses whole and fractional seconds" do
      expect(described_class.parse_retry_after("7")).to eq(7.0)
      expect(described_class.parse_retry_after(" 1.5 ")).to eq(1.5)
    end

    it "returns nil for values it cannot use" do
      expect(described_class.parse_retry_after(nil)).to be_nil
      expect(described_class.parse_retry_after("")).to be_nil
      expect(described_class.parse_retry_after("-1")).to be_nil
      # The HTTP-date form is legal HTTP but not what the A vs B workers emit,
      # and guessing at it would be worse than falling back to the curve.
      expect(described_class.parse_retry_after("Wed, 21 Oct 2026 07:28:00 GMT")).to be_nil
    end
  end

  describe ".reset" do
    it "returns nil so the next call starts at the first rung" do
      expect(described_class.reset).to be_nil
      expect(described_class.next_backoff(described_class.reset, random: no_jitter).delay)
        .to eq(1.0)
    end
  end
end
