# frozen_string_literal: true

require_relative "endpoints"
require_relative "tracker"

module Avsb
  # Event wiring for Avsb::Server: the tracker's lifecycle, the exposure hook
  # handed to the evaluator, and the sticky-hit exposure.
  #
  # Mixed into Avsb::Server rather than living in client.rb so the client file
  # stays about the client's lifecycle. Everything here is private.
  module ServerEvents
    private

    # Build the tracker once a datafile exists, because the ingest origin comes
    # from the datafile. Until then, events queue nowhere and track() says so
    # rather than pretending.
    def start_events
      return if @tracker || !@events_enabled

      datafile = @mutex.synchronize { @datafile }
      return unless datafile

      @tracker = Tracker.new(
        sdk_key: @sdk_key,
        collect_endpoint: collect_endpoint_from(datafile),
        logger: @logger,
      )
    end

    # The datafile publishes the ingest origin; the documented default is the
    # fallback when a datafile predates the field.
    def collect_endpoint_from(datafile)
      endpoint = datafile["collectEndpoint"].to_s
      endpoint.empty? ? Avsb::Endpoints::DEFAULT_COLLECT_HOST : endpoint
    end

    # Exposures reach ingest through the tracker. With events off the evaluator
    # is handed no hook at all, so it does not even build the payload.
    def exposure_hook
      return nil unless @tracker

      ->(event) { @tracker.queue(event) }
    end

    # A sticky hit skips the evaluator, so the exposure it would have fired has
    # to be recorded here. The event is attributed to the rule stored with the
    # assignment; when that rule is gone the pipeline suppresses this call
    # instead, because the experiment no longer exists.
    def record_sticky_exposure(datafile, flag_key, user_id, assignment, variation)
      return unless @tracker

      flag = (datafile["flags"] || []).find { |f| f["key"] == flag_key }
      return unless flag

      @tracker.queue({
        "visitorId"    => user_id,
        "experimentId" => assignment[:rule_id],
        "variationId"  => variation["id"],
        "eventName"    => "flag_exposure",
        "revenue"      => nil,
        "timestamp"    => (Time.now.to_f * 1000).to_i,
        "pageUrl"      => "",
        "properties"   => { "flagKey" => flag_key, "flagId" => flag["id"] },
      })
    end
  end
end
