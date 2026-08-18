/// Indicates the origin of data returned by an operation.
enum DataSource {
  /// Data was fetched from the Firestore network.
  network,

  /// Data was served from the application-level cache.
  cache,

  /// Data was served from a stale cache entry (e.g. during revalidation).
  staleCache,
}
