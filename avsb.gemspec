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
  spec.homepage    = "https://avsb.cloud"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.1.0"

  spec.files = Dir["lib/**/*", "README.md", "avsb.gemspec"]

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
