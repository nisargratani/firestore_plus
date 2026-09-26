/// Optional listener for tracking FirestorePlus internal metrics.
abstract interface class FirestoreMetricsListener {
  /// Called when an operation completes.
  void onOperationComplete(FirestoreOperationMetrics metrics);
}

/// Represents the type of operation performed.
enum FirestoreOperationType {
  /// A single document read (`get`, `getById`).
  get,

  /// A document created with an auto-generated ID (`add`).
  add,

  /// A document written with `set`.
  set,

  /// A document updated with `update`.
  update,

  /// A document deleted with `delete`.
  delete,

  /// An existence check (`exists`).
  exists,

  /// An aggregate count query (`count`).
  count,

  /// A query read (`FirestoreQuery.get`, `FirestoreCollection.get`,
  /// `paginate`).
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

  /// Creates a metrics record. Instances are created by the package and
  /// passed to [FirestoreMetricsListener.onOperationComplete].
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
