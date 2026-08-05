# Changelog

All notable changes to the `avsb` Ruby gem are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

First release with a working data plane. Everything below is pre-launch, so
these are corrections rather than deprecations: there is no earlier published
version to migrate from.

### Fixed

- **The datafile URL.** The gem read
  `https://cdn.avsb.cloud/v1/datafiles/<key>.json`, which does not exist, so no
  Ruby process could ever initialise. URLs now come from `Avsb::Endpoints` and
  nothing composes one by hand.
- **Multi-context evaluation.** `Avsb::Core::Hash` (MurmurHash3) shadowed
  Ruby's `::Hash` inside the `Avsb::Core` namespace, so every
  `ctx.is_a?(Hash)` check was false and multi-context lookups silently missed.
  Kinded audience conditions, dotted `hashAttribute` paths, and holdout
  bucketing against a sub-context all worked only for single contexts.
- **Traffic-allocation and cumulative math.** Thresholds were truncated to
  integers, which moved one bucket in ten thousand relative to the reference
  engine and to the other SDKs. Both the allocation gate and the variation
  walk now compare the raw floating-point product.
- **Holdout thresholds** were floored, putting holdouts one bucket out of step
  with the allocation gate in the same datafile.
- **`enabled?`** returned true for any rule-sourced flag with a Ruby-truthy
  value. It now means "a real decision produced this value, and the value is
  truthy by JavaScript's rules", identical in every SDK. `0` and `""` are
  falsy; the strings `"0"` and `"false"` are truthy.
- **`exists?`** answered true for an uninitialised client.

### Added

- **Event tracking.** `track`, `track_purchase`, and automatic exposure
  recording on `ab_test`, `bandit`, and holdout decisions. `Avsb::Tracker`
  batches with a bounded queue, stamps a stable `eventId` per event, retries
  with jittered exponential backoff, honours `Retry-After`, and flushes on
  `close`. Before this, `track` logged the payload and dropped it, so
  server-side experiments produced no data at all.
- **`not_ready` evaluation source.** Evaluating before a datafile exists
  returns your default with `source: "not_ready"` instead of masquerading as
  `not_found`.
- **Bandit dispatch.** `bandit`-typed rules run through `Avsb::Core::Bandits`.
  With no model store supplied they run the algorithm's cold-start policy, and
  every path that cannot dispatch appends a reason naming why.
- **Commerce and alias audience operators**: `viewed_any`, `not_viewed_any`,
  `has_purchased`, `has_not_purchased`, `lifetime_spend_gt`, `order_count_gt`,
  `last_purchase_older_than`, `between`, plus `is`, `is_not`,
  `does_not_contain`, and `does_not_exist`. An audience using any of them
  matched nobody before.
- **Sticky bucketing, wired.** `sticky_bucket_service:` was accepted and never
  used. `Avsb::StickyPipeline` now reads before the evaluator and writes only
  on an `ab_test` match, storing the variation id.
- **Heartbeat.** Drives the Connected, Stale, and Not connected states on the
  dashboard's Environments page.
- **`wait_for_ready(timeout:)`**, `ready?`, `degraded?`, and `init_result` for
  a blocking, inspectable start-up.
- **Loud failures.** A wrong-shaped SDK key, a 404 datafile, a request that
  never landed, and a dropped event batch each name what failed, the exact URL
  or key involved, and a `curl` that reproduces it.
- **Once-per-process empty-context warning**, naming the call to add.
- **Graceful shutdown.** The refresh thread and the SSE client are signalled
  and joined instead of `Thread#kill`ed, and `close` flushes queued events.
- **`Avsb::Http`**, one place where outbound requests are made, with timeouts
  and proxy support.
- **`Avsb::Backoff`**, the retry curve shared with the other SDKs.
- **`CHANGELOG.md`**, which the gemspec's `changelog_uri` had always pointed at.

### Changed

- `track`'s signature is `track(event_name, context:, revenue: nil, value: nil)`.
  `context:` is required, because an event with no visitor cannot be attributed.
  `revenue` and `value` map one-to-one onto the ingestion contract rather than
  one guessing at the other.
- The default logger prints warnings to stderr in development and nothing in
  production, instead of being silent everywhere.
- A failed initial fetch resolves `{success: false, source: "error", error:}`.
  `degraded?` is separate, and means "serving an older datafile because a
  refresh failed".
- `Avsb::Core::DecideOption` lists only the two options that exist.

### Removed

- `identify`, which logged its argument and dropped it. There is no identify
  endpoint in the data plane, so the method promised something the platform
  does not do.
- `Avsb::Core::BigSegmentStore`, an orphan with no call site in any SDK.
  Big segments need platform design before any port implements them.
