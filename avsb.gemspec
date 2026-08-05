# frozen_string_literal: true

require_relative "lib/avsb/version"

Gem::Specification.new do |spec|
  spec.name    = "avsb"
  spec.version = Avsb::VERSION
  spec.authors = ["A vs B"]
  spec.email   = ["sdk@avsb.cloud"]

  spec.summary     = "A vs B feature-flag and experiment SDK for Ruby."
  spec.description = "Server-side Ruby SDK for the A vs B platform. " \
                     "Evaluates feature flags and A/B experiments against a " \
                     "downloaded datafile, with support for holdouts, bandits, " \
                     "multi-context audiences, sticky bucketing, and OpenFeature."
  spec.homepage    = "https://github.com/avsbhq/avsb-ruby"
  spec.license     = "MIT"

  spec.metadata = {
    "homepage_uri"      => "https://avsb.cloud",
    "source_code_uri"   => "https://github.com/avsbhq/avsb-ruby",
    "bug_tracker_uri"   => "https://github.com/avsbhq/avsb-ruby/issues",
    "documentation_uri" => "https://avsb.cloud/docs",
    "changelog_uri"     => "https://github.com/avsbhq/avsb-ruby/blob/main/CHANGELOG.md"
  }

  spec.required_ruby_version = ">= 3.1.0"

  # CHANGELOG.md ships in the gem because metadata["changelog_uri"] points at
  # it, and that link was dead until the file existed.
  spec.files = Dir["lib/**/*", "README.md", "CHANGELOG.md", "LICENSE", "avsb.gemspec"]

  # Runtime: zero hard dependencies — optional integrations guard-require at call-time.

  # Optional integrations (documented in README):
  #   gem "redis", "~> 5.0"          # for Avsb::Sticky::Redis
  #   gem "aws-sdk-dynamodb", "~> 1" # for Avsb::Sticky::DynamoDB
  #   gem "openfeature-sdk"          # for Avsb::OpenFeatureProvider
  #   gem "rack", "~> 3.0"           # for Avsb::Middleware::Rack
  #   gem "railties"                 # for Avsb::Middleware::Rails

  spec.add_development_dependency "rspec",  "~> 3.13"
  spec.add_development_dependency "rack",   "~> 3.0"
  spec.add_development_dependency "rake",   "~> 13.0"
end
