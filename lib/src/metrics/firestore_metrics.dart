/// Optional listener for tracking FirestorePlus internal metrics.
abstract interface class FirestoreMetricsListener {
  /// Called when an operation completes.
  void onOperationComplete(FirestoreOperationMetrics metrics);
}

/// Represents the type of operation performed.
enum FirestoreOperationType {
  get,
  add,
  set,
  update,
  delete,
  exists,
  count,
  query,
}

/// Contains metadata and metrics about a completed operation.
class FirestoreOperationMetrics {
  /// The type of operation performed.
  final FirestoreOperationType type;

  /// The collection path or full document path involved.
  final String path;

  /// Duration the entire operation took (including retries and cache checks).
  final Duration duration;

  /// Whether the result was served from the cache.
  final bool servedFromCache;

  /// Whether the operation succeeded.
  final bool isSuccess;

  /// Number of retries attempted.
  final int retryCount;

  /// Any exception that was thrown.
  final Object? error;

  const FirestoreOperationMetrics({
    required this.type,
    required this.path,
    required this.duration,
    required this.servedFromCache,
    required this.isSuccess,
    required this.retryCount,
    this.error,
  });
}
