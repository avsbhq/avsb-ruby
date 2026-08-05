# frozen_string_literal: true

require "spec_helper"

RSpec.describe Avsb::DatafilePoller do
  let(:logger) { Avsb::NoopLogger.new }
  let(:sdk_key) { "sdk_production_pollerfixture01" }

  def build(**overrides)
    described_class.new(
      sdk_key: sdk_key,
      logger: logger,
      on_update: ->(_df) {},
      on_error: ->(_err) {},
      **overrides
    )
  end

  describe "the URL it reads" do
    it "is the canonical datafile URL, not any of the shapes that 404" do
      expect(build.url).to eq("https://cdn.avsb.cloud/#{sdk_key}/datafile.json")
    end

    it "honours a custom CDN origin for a proxy or local dev" do
      poller = build(cdn_host: "http://localhost:3000/")
      expect(poller.url).to eq("http://localhost:3000/#{sdk_key}/datafile.json")
    end

    it "refuses to build a URL with no key rather than fetching cdn.avsb.cloud//" do
      expect { described_class.new(sdk_key: "", logger: logger, on_update: ->(_) {},
                                  on_error: ->(_) {}) }
        .to raise_error(ArgumentError, /without an SDK key/)
    end
  end

  describe "#fetch_once" do
    it "returns the parsed datafile on success" do
      allow(Avsb::Http).to receive(:get)
        .and_return(Avsb::Http::Response.new(200, '{"version":2,"flags":[]}', nil, nil))

      expect(build.fetch_once).to eq({ datafile: { "version" => 2, "flags" => [] } })
    end

    it "explains a 404 in terms of publishing, and prints a curl" do
      allow(Avsb::Http).to receive(:get)
        .and_return(Avsb::Http::Response.new(404, "not found", nil, nil))

      message = build.fetch_once[:error].message
      expect(message).to include("HTTP 404")
      expect(message).to include("https://cdn.avsb.cloud/#{sdk_key}/datafile.json")
      expect(message).to include("publish")
      expect(message).to include("curl -i https://cdn.avsb.cloud/#{sdk_key}/datafile.json")
    end

    it "explains a request that never landed" do
      allow(Avsb::Http).to receive(:get)
        .and_return(Avsb::Http::Response.new(0, "", "SocketError: getaddrinfo failed", nil))

      message = build.fetch_once[:error].message
      expect(message).to include("failed before it got a response")
      expect(message).to include("SocketError")
      expect(message).to include("proxy or firewall")
    end

    it "explains a body that is not JSON instead of raising" do
      allow(Avsb::Http).to receive(:get)
        .and_return(Avsb::Http::Response.new(200, "<html>captive portal</html>", nil, nil))

      message = build.fetch_once[:error].message
      expect(message).to include("was not JSON")
      expect(message).to include("captive portal")
    end
  end

  describe "#close" do
    it "is safe before start" do
      expect { build.close }.not_to raise_error
    end

    it "stops a running loop without killing the thread" do
      allow(Avsb::Http).to receive(:get)
        .and_return(Avsb::Http::Response.new(200, '{"version":2,"flags":[]}', nil, nil))
      poller = build(polling_interval: 30)
      poller.start
      expect(poller.running?).to be true

      poller.close(timeout: 5)

      expect(poller.running?).to be false
    end
  end
end
