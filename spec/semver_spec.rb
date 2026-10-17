# frozen_string_literal: true

require "spec_helper"

# The version grammar. The rows are the ones
# packages/avsb-core/src/semver.test.ts runs, so every port is held to the
# same grammar, not just the same corpus.
RSpec.describe Avsb::Core::SemVer do
  def parsed(major, minor, patch, *prerelease)
    described_class::Parsed.new(major: major, minor: minor, patch: patch, prerelease: prerelease)
  end

  def must_parse(input)
    version = described_class.parse(input)
    raise "test row does not parse: #{input.inspect}" if version.nil?

    version
  end

  operators = %w[semver_eq semver_neq semver_gt semver_gte semver_lt semver_lte]

  describe ".parse" do
    {
      "1.2.3" => %w[1 2 3],
      "0.0.0" => %w[0 0 0],
      "v1.2.3" => %w[1 2 3],
      "V1.2.3" => %w[1 2 3],
      "2" => %w[2 0 0],
      "2.3" => %w[2 3 0],
      "v2" => %w[2 0 0],
      "  2.3.0\t" => %w[2 3 0],
      "\n\v\f1.0.0\r\n" => %w[1 0 0],
      "1.0.0-alpha" => %w[1 0 0 alpha],
      "1.0.0-alpha.1" => %w[1 0 0 alpha 1],
      "1.0.0-0.3.7" => %w[1 0 0 0 3 7],
      "1.0.0-x-y-z.--" => %w[1 0 0 x-y-z --],
      "1.0.0-0a" => %w[1 0 0 0a],
      "1.0.0+20130313144700" => %w[1 0 0],
      "1.0.0-beta+exp.sha.5114f85" => %w[1 0 0 beta],
      "1.0.0+21AF26D3----117B344092BD" => %w[1 0 0],
      "1.0.0+001" => %w[1 0 0],
      "2-beta" => %w[2 0 0 beta],
      "1-2.3" => %w[1 0 0 2 3],
      "18446744073709551616.0.0" => %w[18446744073709551616 0 0]
    }.each do |input, (major, minor, patch, *prerelease)|
      it "reads #{input.inspect}" do
        expect(described_class.parse(input)).to eq(parsed(major, minor, patch, *prerelease))
      end
    end

    [
      "", "   ", "v", "V", "banana", "2.x", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03",
      "1.2.3-01", "1.2.3-", "1.2.3+", "1.2.3-alpha..1", "1.2.3+build..1", "1.", ".1",
      "1..2", "vv1.2.3", "v 1.2.3", "1.2.3 beta", "1.2.3-beta_1", "1.2.3-béta",
      "١.٢.٣", "1.2.3+build+more", "=1.2.3", "-1.2.3", "+1.2.3",
      "1.2.3 ", " 1.2.3", "1.2.3\n2.0.0", " 1 .2.3", "1.2.3\u0000"
    ].each do |input|
      it "refuses #{input.inspect}" do
        expect(described_class.parse(input)).to be_nil
      end
    end
  end

  describe ".compare" do
    [
      ["1.0.0", "2.0.0", -1],
      ["2.0.0", "2.1.0", -1],
      ["2.1.0", "2.1.1", -1],
      ["2.10.0", "2.9.1", 1],
      ["1.0.0", "1.0.0", 0],
      ["2", "2.0.0", 0],
      ["v2.3", "2.3.0", 0],
      ["1.0.0+build1", "1.0.0+build2", 0],
      ["1.0.0-rc.1+build.5", "1.0.0-rc.1", 0],
      ["1.0.0-alpha", "1.0.0", -1],
      ["1.0.0-Beta", "1.0.0-alpha", -1],
      ["1.0.0-1", "1.0.0-a", -1],
      ["1.0.0-2", "1.0.0-10", -1],
      ["1.0.0-a-b", "1.0.0-a", 1],
      ["18446744073709551616.0.0", "18446744073709551615.0.0", 1],
      ["99999999999999999999.0.0", "100000000000000000000.0.0", -1]
    ].each do |left, right, order|
      it "orders #{left} against #{right} as #{order}" do
        expect(described_class.compare(must_parse(left), must_parse(right))).to eq(order)
        expect(described_class.compare(must_parse(right), must_parse(left))).to eq(-order)
      end
    end

    it "orders the SemVer 2.0.0 section 11 pre-release chain" do
      chain = %w[1.0.0-alpha 1.0.0-alpha.1 1.0.0-alpha.beta 1.0.0-beta 1.0.0-beta.2 1.0.0-beta.11 1.0.0-rc.1 1.0.0]
      chain.each_cons(2) do |lower, higher|
        expect(described_class.compare(must_parse(lower), must_parse(higher))).to eq(-1)
        expect(described_class.compare(must_parse(higher), must_parse(lower))).to eq(1)
      end
    end
  end

  describe ".evaluate" do
    [
      ["semver_eq", "2.3.0", "2.3", true],
      ["semver_eq", "2.3.1", "2.3", false],
      ["semver_neq", "2.3.1", "2.3.0", true],
      ["semver_neq", "v2.3.0", "2.3", false],
      ["semver_gt", "2.10.0", "2.9.1", true],
      ["semver_gt", "2.9.1", "2.9.1", false],
      ["semver_gte", "2.9.1", "2.9.1", true],
      ["semver_gte", "2.9.0", "2.9.1", false],
      ["semver_lt", "2.0.0-beta.2", "2.0.0", true],
      ["semver_lt", "2.0.0", "2.0.0", false],
      ["semver_lte", "2.0.0", "2.0.0", true],
      ["semver_lte", "2.0.1", "2.0.0", false]
    ].each do |operator, actual, expected, result|
      it "answers #{operator} #{actual} against #{expected} with #{result}" do
        expect(described_class.evaluate(operator, actual, expected)).to be(result)
      end
    end

    it "reads a number attribute the way JavaScript prints it" do
      expect(described_class.evaluate("semver_eq", 2, "2.0.0")).to be(true)
      expect(described_class.evaluate("semver_eq", 2.0, "2.0.0")).to be(true)
      expect(described_class.evaluate("semver_lt", 2.5, "2.10.0")).to be(true)
      expect(described_class.evaluate("semver_eq", -0.0, "0.0.0")).to be(true)
      expect(described_class.evaluate("semver_gte", -2, "0.0.0")).to be(false)
      expect(described_class.evaluate("semver_gte", 1e21, "0.0.0")).to be(false)
    end

    it "fails closed on wrong types and unparsable sides, semver_neq included" do
      operators.each do |operator|
        [true, false, nil, {}, ["2.0.0"], :v2].each do |actual|
          expect(described_class.evaluate(operator, actual, "2.0.0")).to be(false)
        end
        expect(described_class.evaluate(operator, "3.0.0", "2.x")).to be(false)
        expect(described_class.evaluate(operator, "1.2.3.4", "2.0.0")).to be(false)
      end
      expect(described_class.evaluate("semver_eq", "2.0.0", 2)).to be(false)
      expect(described_class.evaluate("semver_between", "2.0.0", "2.0.0")).to be(false)
    end
  end

  describe "through the audience evaluator" do
    def version_condition(operator, value)
      {
        "id" => "c1", "type" => "CUSTOM_ATTRIBUTE", "attribute" => "appVersion",
        "operator" => operator, "value" => value
      }
    end

    it "routes every version operator, reading the first entry of a list value" do
      newer = { "kind" => "user", "key" => "u1", "appVersion" => "2.10.0" }
      older = { "kind" => "user", "key" => "u2", "appVersion" => "2.9.0" }
      condition = version_condition("semver_gt", "2.9.1")

      expect(Avsb::Core::Audience.evaluate_condition(condition, newer)).to be(true)
      expect(Avsb::Core::Audience.evaluate_condition(condition, older)).to be(false)
      expect(Avsb::Core::Audience.evaluate_condition(version_condition("semver_gte", %w[2.3.0 9.9.9]), newer))
        .to be(true)
    end

    it "does not count a missing attribute as a different version" do
      missing = { "kind" => "user", "key" => "u3" }
      expect(Avsb::Core::Audience.evaluate_condition(version_condition("semver_neq", "2.0.0"), missing))
        .to be(false)
    end
  end
end
