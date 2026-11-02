## 0.1.0

Fixes from an external QA pass (issue IDs FSP-01 to FSP-11). Each fix has a
regression test in `test/regressions_0_1_0_test.dart`.

### Bug fixes

* FSP-01: `networkFirst` (the default policy) no longer serves cached data
  when the server rejects a read (e.g. `permission-denied`); only transient
  errors fall back to the cache, and the fallback warning includes the error.
* FSP-02: a read that is in flight while its document or collection is
  written, invalidated or `cache.clear()`ed no longer stores its pre-write
  result in the cache.
* FSP-03: dependency constraints now allow `cloud_firestore` 7.x and
  `firebase_core` 5.x (see Dependencies).
* FSP-04: request deduplication no longer hands a read that started after a
  completed write the result of an older, pre-write read.
* FSP-05: `RetryPolicy.retryIf` now receives the normalized
  `FirestorePlusException`, so the README "Custom retry predicate" example
  retries as documented.
* FSP-06: writes no longer retry timeouts when a custom `retryIf` is set, so
  a `FieldValue.increment` can no longer be applied more than once.
* FSP-07: warning-level logs no longer print query cache keys, which contain
  filter values such as e-mail addresses; they name the operation instead.
* FSP-08: metrics no longer report a `cacheOnly` miss as
  `servedFromCache: true`.
* FSP-09: `staleWhileRevalidate` runs at most one background refresh per
  cache key at a time instead of one per cache hit.
* FSP-10: the per-collection registry of query cache keys is capped at
  `CacheManager.maxTrackedQueryKeysPerCollection` (500), so memory and the
  work done by each write stay bounded.
* FSP-11: `toFirestore` failures in `FirestoreBatch.set` and
  `FirestoreTransaction.set` now throw a `serialization`
  `FirestorePlusException` (with `path`), like `set` does.

### Dependencies

* `cloud_firestore: ">=6.8.0 <8.0.0"` and `firebase_core: ">=4.13.0 <6.0.0"`
  (were `^6.8.0` / `^4.13.0`). The 7.x / 5.x majors keep the same Dart API
  but need Firebase Apple SDK 13 (macOS 11 with Swift Package Manager) and
  Android `minSdk 24`. Tested at both ends of the range.
* Dev: `fake_cloud_firestore: ^4.4.0` (first release that allows
  `cloud_firestore` 7); `pub_semver` and `yaml` for the constraint test.

### Behaviour changes to note

* `networkFirst` no longer masks non-transient errors: `permissionDenied`,
  `notFound`, `invalidArgument` and `unknown` errors are thrown even when the
  document or query is cached. Only `network`, `unavailable`, `timeout` and
  `resourceExhausted` fall back to the cache.
* `retryIf` now receives a `FirestorePlusException` instead of the raw
  `FirebaseException` / `TimeoutException`. Predicates that check
  `error is FirebaseException` must check `error.type` (or
  `error.originalException`) instead.
* Writes (`set`, `update`, `delete`, `add`) never retry timeouts, even with a
  custom `retryIf`; `retryIf` still decides about every other error.
* When a collection has more than 500 distinct cached queries, the least
  recently used query result is evicted from the cache store.

## 0.0.3

### Bug fixes

* Metrics: `add()` now reports `FirestoreOperationType.add` (was `set`), and
  query reads (`FirestoreQuery.get`, `FirestoreCollection.get`, `paginate`)
  report `FirestoreOperationType.query` (was `get`). Both enum values existed
  but were never emitted.
* Docs for `fromFirestore` / `toFirestore` on `FirestoreCollection` and
  `FirestoreDocument` described them the wrong way round.

### Documentation

* DartDoc for the library, all public constructors and every
  `FirestoreOperationType` value; `dart doc` reports no warnings.
* `RetryPolicy` documents the backoff formula and that `maxAttempts` counts
  retries after the first attempt.
* README: metrics types, and that query results persisted by a previous app
  session are not tracked for write invalidation (use a TTL or
  `invalidateCollection`).

### Tooling

* GitHub Actions CI: format, analyze, test, example analysis, publish dry-run,
  and a job at dependency lower bounds.
* Additional lints for async safety (`unawaited_futures`,
  `discarded_futures`, `cancel_subscriptions`, `close_sinks`, …).

### Behaviour change to note

* Metrics listeners that filter on `FirestoreOperationType.get` or `.set`
  will no longer see query reads or `add()` calls there; handle `.query` and
  `.add` as well.

## 0.0.2

Fixes found by integration-testing the package from a fresh consumer app
against the Firestore emulator (macOS and Android).

### Bug fixes

* Retry: jitter no longer crashes with `RangeError` when the backoff delay is
  1 ms; very large attempt counts clamp to `maxDelay` instead of overflowing.
* Writes (`set`, `update`, `delete`, `add`) no longer retry timeouts by
  default. A timed-out write is still queued by Firestore, so retrying could
  apply it more than once (e.g. `FieldValue.increment` applied 4 times).
* `FirestorePlusException.path` is now set for network errors (was `null`).
* Batch commit and transaction errors keep their real type and code
  (e.g. `permissionDenied`, `notFound`) instead of `unknown`.
* `runTransaction` now throws `FirestorePlusException` for Firestore failures;
  exceptions thrown by your own code inside the transaction are rethrown
  unchanged.
* Document and query streams emit Firestore errors as `FirestorePlusException`.
* Transaction reads that fail to deserialize report `serialization`.
  `toFirestore` failures in `set` report `serialization`.
* Writes (including batches and transactions) now invalidate the cached query
  results of the affected collection, not only the document.
  Transactions previously invalidated nothing.
* `invalidateCollection` / `MemoryCacheStore.clearCollection` now also clear
  cached query results.
* `staleWhileRevalidate` on a cache miss now throws network errors instead of
  returning `null` as if the document did not exist.
* A document found missing on the server is removed from the cache, so it is
  no longer served later by `cacheOnly` or a `networkFirst` fallback.
* Query cache keys are collision-free: different `Filter` queries (and cursor
  values containing commas) no longer share a cache entry.
* `paginate`: `hasMore` is exact (fetches `limit + 1`), no extra empty page;
  cached pages no longer contain a `DocumentSnapshot`, so persistent cache
  stores work; a cursor is still returned for pages served from cache.
  `limit <= 0` throws `ArgumentError`.
* `MemoryCacheStore` copies values, so mutating a returned map no longer
  corrupts the cache.
* Metrics: `retryCount` and `servedFromCache` are now accurate (were always
  `0` / `false`). A throwing metrics listener no longer fails the operation.
* Request deduplication no longer shares results between reads with different
  cache policies.
* Custom loggers now only receive messages at or above their `logLevel`
  (previously every debug message was delivered; only
  `ConsoleFirestoreLogger` filtered). New `FirestorePlusLogger.isEnabled`.

### Other

* `CacheManager` is exported (the type of `FirestorePlus.cache`) and gains
  `invalidateDocument` and `invalidateQueries`.
  `RetryExecutor.execute` gains optional `path` and `onRetry` parameters.
* Environment constraints now match the dependencies: Dart `^3.6.0`,
  Flutter `>=3.27.0`. `meta` relaxed to `^1.15.0` (was `^1.18.0`, which
  excluded Flutter releases before 3.41).
* README corrected to match actual behaviour (missing documents return `null`,
  retry/timeout semantics, cache invalidation scope, custom store contract).
* The example is now a runnable app (emulator-first, no Firebase project
  needed).

### Behaviour changes to note

* Stream and `runTransaction` errors are now `FirestorePlusException` instead
  of `FirebaseException`.
* Query cache keys changed format; entries in a persistent custom store from
  0.0.1 will simply miss.

## 0.0.1

* Initial development release.
* Support for typed collections, documents, and queries.
* Caching framework (`CacheManager`, `MemoryCacheStore`).
* Retry engine with exponential backoff and jitter.
* Built-in error mapping and normalizer (`FirestorePlusException`).
* Request deduplication for read operations.
* Cursor-based pagination (`PaginatedResult`).
* `FirestoreBatch` and `FirestoreTransaction` wrappers.
* Structured logging and operation metrics.
