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
