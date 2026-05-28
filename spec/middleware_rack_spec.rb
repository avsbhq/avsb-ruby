# frozen_string_literal: true

require "spec_helper"

begin
  require "rack"
  require "rack/mock"
  RACK_AVAILABLE = true
rescue LoadError
  RACK_AVAILABLE = false
end

RSpec.describe Avsb::Middleware::Rack do
  if RACK_AVAILABLE
    let(:inner_app) do
      lambda { |env|
        client = env["avsb.client"]
        body   = client ? "client_present" : "client_missing"
        [200, { "Content-Type" => "text/plain" }, [body]]
      }
    end

    let(:fake_client) do
      double("Avsb::Server").tap do |d|
        # No expectations — presence in env is sufficient.
      end
    end

    subject(:middleware) { described_class.new(inner_app, client: fake_client) }

    it "mounts without raising" do
      expect { middleware }.not_to raise_error
    end

    it "sets avsb.client in the Rack env" do
      request  = ::Rack::MockRequest.new(middleware)
      response = request.get("/")
      expect(response.body).to eq("client_present")
    end

    it "returns the inner app's status code unchanged" do
      request  = ::Rack::MockRequest.new(middleware)
      response = request.get("/")
      expect(response.status).to eq(200)
    end

    it "passes env through unmodified except for the avsb.client key" do
      captured_env = nil
      probe_app    = lambda { |env| captured_env = env; [200, {}, []] }
      mw           = described_class.new(probe_app, client: fake_client)
      ::Rack::MockRequest.new(mw).get("/health")
      expect(captured_env["avsb.client"]).to eq(fake_client)
      expect(captured_env["PATH_INFO"]).to    eq("/health")
    end
  else
    it "skips Rack middleware tests when rack gem is unavailable" do
      skip "rack gem not installed"
    end
  end
end
