import '../cache/cache_policy.dart';
import '../cache/cache_store.dart';
import '../logging/firestore_plus_logger.dart';
import '../metrics/firestore_metrics.dart';
import '../retry/retry_policy.dart';

/// Global configuration for FirestorePlus.
class FirestorePlusConfig {
  /// The default cache policy for read operations.
  final CachePolicy defaultCachePolicy;

  /// The default duration to keep entries in cache.
  final Duration? defaultCacheDuration;

  /// The default retry policy for operations.
  final RetryPolicy defaultRetryPolicy;

  /// The default timeout for operations.
  final Duration defaultTimeout;

  /// Whether to enable request deduplication (coalescing identical concurrent reads).
  final bool enableRequestDeduplication;

  /// The cache store implementation to use. If null, a default memory cache is used.
  final FirestoreCacheStore? cacheStore;

  /// The logger implementation to use.
  final FirestorePlusLogger logger;

  /// An optional listener for metrics.
  final FirestoreMetricsListener? metricsListener;

  /// Creates a configuration. Defaults: `networkFirst` caching with no TTL,
  /// exponential retry (3 retries), a 30 second timeout, deduplication on,
  /// an in-memory cache of 500 entries and an info-level console logger.
  const FirestorePlusConfig({
    this.defaultCachePolicy = CachePolicy.networkFirst,
    this.defaultCacheDuration,
    this.defaultRetryPolicy = const RetryPolicy.exponential(),
    this.defaultTimeout = const Duration(seconds: 30),
    this.enableRequestDeduplication = true,
    this.cacheStore,
    this.logger = const ConsoleFirestoreLogger(),
    this.metricsListener,
  });
}
