import '../cache/cache_policy.dart';
import '../retry/retry_policy.dart';

/// Options for an individual Firestore operation.
class FirestoreOperationOptions {
  /// The cache policy to use. Overrides the global default if provided.
  final CachePolicy? cachePolicy;

  /// The cache duration (TTL). Overrides the global default if provided.
  final Duration? cacheDuration;

  /// The retry policy to use. Overrides the global default if provided.
  final RetryPolicy? retryPolicy;

  /// The timeout for the operation. Overrides the global default if provided.
  final Duration? timeout;

  const FirestoreOperationOptions({
    this.cachePolicy,
    this.cacheDuration,
    this.retryPolicy,
    this.timeout,
  });

  /// Merges these options with another set of options, preferring the values from the other set.
  FirestoreOperationOptions merge(FirestoreOperationOptions? other) {
    if (other == null) return this;
    return FirestoreOperationOptions(
      cachePolicy: other.cachePolicy ?? cachePolicy,
      cacheDuration: other.cacheDuration ?? cacheDuration,
      retryPolicy: other.retryPolicy ?? retryPolicy,
      timeout: other.timeout ?? timeout,
    );
  }
}
