# frozen_string_literal: true

require "cgi"

module Avsb
  # Data-plane endpoint contract (SDK/API DX overhaul spec 1.1).
  #
  # Single source of truth for every network target this SDK talks to.
  # Mirror of packages/avsb-core/src/endpoints.ts; both are locked by the
  # "endpoints" conformance fixture family
  # (packages/avsb-conformance/fixtures/endpoints/manifest.json).
  #
  # Nothing in this SDK may compose a data-plane URL by hand. Change a URL
  # here and the fixture changes with it, in the same commit, or every
  # SDK's conformance run fails.
  #
  # Credential posture:
  #   * Datafile and preview reads are keyless by path. The SDK key is the
  #     path segment: no header, no query string, no Authorization.
  #   * Event sends carry sdkKey in the JSON body envelope.
  #   * The stream ticket request is the one read that takes the key as a
  #     query parameter.
  #   * No Authorization header anywhere on the data plane.
  module Endpoints
    # Default hosts. Overridable for self-hosted proxies, local dev, and
    # tests. Nothing here points at a host that does not exist:
    # datafile.avsb.cloud and stream.avsb.cloud are NOT real and must
    # never appear as defaults.
    DEFAULT_CDN_HOST     = "https://cdn.avsb.cloud"
    DEFAULT_COLLECT_HOST = "https://ingest.avsb.cloud"
    DEFAULT_APP_HOST     = "https://app.avsb.cloud"

    # Every ingestion path, keyed by what it carries. Appended to a
    # collect ORIGIN (see .collect_url).
    #
    # Keys are snake_case here to stay idiomatic; the conformance fixtures
    # use the canonical camelCase ids ("metricBatch" for "metric_batch").
    # What is locked across languages is the PATH, not the local key
    # spelling.
    COLLECT_PATHS = {
      "single" => "/v1/collect",
      "batch" => "/v1/collect/batch",
      "metric_batch" => "/v1/collect/metric-batch",
      "orders" => "/v1/collect/orders",
      "errors" => "/v1/collect/errors",
      "ping" => "/v1/ping",
      "geo" => "/v1/geo"
    }.freeze

    STREAM_TICKET_PATH = "/api/sdk/stream"
    HEARTBEAT_PATH     = "/api/sdk/heartbeat"

    DATAFILE_FILENAME = "datafile.json"
    PREVIEW_FILENAME  = "preview.json"

    # Outcome of .resolve_stream_endpoint. `available` false carries an
    # actionable `reason` and no endpoint: never guess a host.
    StreamEndpointResolution = Struct.new(:available, :endpoint, :source, :reason) do
      def available?
        available
      end
    end

    STREAM_UNAVAILABLE_REASON = 'Streaming is on, but there is no stream endpoint to connect ' \
      'to: the datafile carries no "streamEndpoint" field and no stream_endpoint: option was ' \
      "passed. Republish the environment from the A vs B dashboard (Environments, in the " \
      "project sidebar) to pick up the field, or pass stream_endpoint: explicitly. Polling stays " \
      "on in the meantime, so flag changes still arrive, just on the polling interval instead " \
      "of instantly."

    class << self
      # Canonical datafile URL: {cdn_host}/{sdk_key}/datafile.json.
      #
      # This is the ONLY correct shape. "/v1/datafiles/{key}.json",
      # "/datafiles/{key}.json", and datafile.avsb.cloud/v2/{key} were all
      # bugs and all 404.
      def datafile_url(sdk_key, cdn_host: DEFAULT_CDN_HOST)
        key = require_sdk_key(sdk_key, "datafile_url")
        "#{trim_trailing_slashes(cdn_host)}/#{key}/#{DATAFILE_FILENAME}"
      end

      # Per-environment preview snapshot. Served with no-store.
      def preview_url(sdk_key, cdn_host: DEFAULT_CDN_HOST)
        key = require_sdk_key(sdk_key, "preview_url")
        "#{trim_trailing_slashes(cdn_host)}/#{key}/#{PREVIEW_FILENAME}"
      end

      # CDN object key for the live datafile.
      def datafile_object_key(sdk_key)
        "#{require_sdk_key(sdk_key, 'datafile_object_key')}/#{DATAFILE_FILENAME}"
      end

      # CDN object key for the preview snapshot.
      def preview_object_key(sdk_key)
        "#{require_sdk_key(sdk_key, 'preview_object_key')}/#{PREVIEW_FILENAME}"
      end

      # Normalise a datafile collectEndpoint value down to a bare origin.
      #
      # The flag datafile publishes an origin; the web-experiment datafile
      # publishes the full batch URL. Both are valid inputs, so an SDK can
      # never produce "/v1/collect/batch/v1/collect/batch".
      def collect_origin_from(collect_endpoint)
        trimmed = trim_trailing_slashes(collect_endpoint.to_s.strip)
        COLLECT_PATHS.each_value do |path|
          return trimmed[0, trimmed.length - path.length] if trimmed.end_with?(path)
        end
        trimmed
      end

      # Build an ingestion URL. `kind` is a key of COLLECT_PATHS.
      def collect_url(kind, collect_endpoint: DEFAULT_COLLECT_HOST)
        path = COLLECT_PATHS[kind.to_s]
        unless path
          raise ArgumentError,
                "collect_url got an unknown endpoint kind #{kind.inspect}. " \
                "Known kinds: #{COLLECT_PATHS.keys.sort.join(', ')}."
        end

        "#{collect_origin_from(collect_endpoint)}#{path}"
      end

      # Resolve the stream ticket endpoint. Precedence: explicit option,
      # then the server-controlled datafile field, then nothing.
      def resolve_stream_endpoint(option_endpoint: nil, datafile_stream_endpoint: nil)
        option = option_endpoint.to_s.strip
        unless option.empty?
          return StreamEndpointResolution.new(true, trim_trailing_slashes(option), "option", nil)
        end

        from_datafile = datafile_stream_endpoint.to_s.strip
        unless from_datafile.empty?
          return StreamEndpointResolution.new(
            true, trim_trailing_slashes(from_datafile), "datafile", nil
          )
        end

        StreamEndpointResolution.new(false, nil, nil, STREAM_UNAVAILABLE_REASON)
      end

      # Step 1 of streaming: the ticket request URL.
      def stream_ticket_url(stream_endpoint, sdk_key)
        key = require_sdk_key(sdk_key, "stream_ticket_url")
        "#{trim_trailing_slashes(stream_endpoint)}?sdkKey=#{query_value(key)}"
      end

      # Step 2 of streaming: the SSE URL.
      #
      # subscribe_base_url is the "url" field the TICKET RESPONSE handed back,
      # not the ticket endpoint itself. The token rides in the query string
      # because SSE clients cannot set request headers; tokens expire in 60
      # seconds.
      def stream_subscribe_url(subscribe_base_url, sdk_key, token)
        key = require_sdk_key(sdk_key, "stream_subscribe_url")
        "#{trim_trailing_slashes(subscribe_base_url)}?sdkKey=#{query_value(key)}" \
          "&token=#{query_value(token)}"
      end

      # Fallback stream ticket URL, for docs and tests.
      def stream_endpoint_url(app_host: DEFAULT_APP_HOST)
        "#{trim_trailing_slashes(app_host)}#{STREAM_TICKET_PATH}"
      end

      # Fallback heartbeat URL, for docs and tests.
      def heartbeat_url(app_host: DEFAULT_APP_HOST)
        "#{trim_trailing_slashes(app_host)}#{HEARTBEAT_PATH}"
      end

      # nil means "do not send heartbeats". Deliberately not defaulted to
      # app.avsb.cloud: a proxied deployment publishes its own origin, and
      # heartbeats posted to the wrong host would report liveness nowhere
      # while looking healthy.
      def resolve_heartbeat_endpoint(datafile_heartbeat_endpoint)
        value = datafile_heartbeat_endpoint.to_s.strip
        value.empty? ? nil : value
      end

      private

      def trim_trailing_slashes(host)
        host.to_s.sub(%r{/+\z}, "")
      end

      # Percent-encode a query VALUE.
      #
      # CGI.escape is FORM encoding: it turns a space into "+" and a literal
      # plus into "%2B". A "+" is legal in a form body but means a space to a
      # query-string reader, so forwarding form encoding into a query value
      # sends a different token than the reference implementation does. Any "+"
      # left after escaping can only have come from a space (a literal plus is
      # already %2B), so rewriting it to %20 is safe and matches
      # encodeURIComponent. Locked by the endpoints fixture case
      # stream_subscribe_url_encodes_a_space_as_percent20.
      def query_value(value)
        CGI.escape(value.to_s).gsub("+", "%20")
      end

      # Loud guard: an empty key builds
      # "https://cdn.avsb.cloud//datafile.json", which 404s at the edge
      # with nothing in the message to explain why. Full key-shape
      # validation belongs in Server#initialize (spec 1.2); this only
      # catches "nothing was passed".
      def require_sdk_key(sdk_key, fn_name)
        trimmed = sdk_key.to_s.strip
        if trimmed.empty?
          raise ArgumentError,
                "#{fn_name} was called without an SDK key. Pass the environment SDK key " \
                '(it looks like "sdk_production_xxxxxxxx"), which you can copy from ' \
                "Environments in the project sidebar, in the A vs B dashboard."
        end

        trimmed
      end
    end
  end
end
