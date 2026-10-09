# frozen_string_literal: true

require "spec_helper"
require "rubygems"

# Release metadata that has to agree with itself. The heartbeat reports
# Avsb::VERSION, so a release that bumps one file and forgets another reports
# the wrong version to the dashboard (the drift the JavaScript SDKs shipped,
# N0-9). And the gemspec promised Ruby 3.1 while the code needs 3.2.
RSpec.describe "avsb release metadata" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:gemspec) { Gem::Specification.load(File.join(root, "avsb.gemspec")) }

  it "reports the version of the newest changelog entry" do
    newest = File.read(File.join(root, "CHANGELOG.md"))[/^## \[(\d+\.\d+\.\d+)\]/, 1]
    expect(Avsb::VERSION).to eq(newest)
    expect(gemspec.version.to_s).to eq(Avsb::VERSION)
  end

  it "requires the Ruby that introduced Data.define, which the gem uses" do
    expect(gemspec.required_ruby_version.satisfied_by?(Gem::Version.new("3.2.0"))).to be(true)
    expect(gemspec.required_ruby_version.satisfied_by?(Gem::Version.new("3.1.6"))).to be(false)
  end

  it "states the same Ruby floor in the README" do
    readme = File.read(File.join(root, "README.md"))
    expect(readme).to include("Ruby 3.2 or later")
    expect(readme).not_to include("Ruby 3.1 or later")
  end
end
