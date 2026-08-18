/// Defines how cache should be utilized during read operations.
enum CachePolicy {
  /// Always bypass cache and fetch from the network.
  networkOnly,

  /// Read from cache first; if missing or stale, fetch from network.
  cacheFirst,

  /// Read only from cache; never fetch from network.
  cacheOnly,

  /// Always fetch from the network first; if it fails, read from cache.
  networkFirst,

  /// Return cached data immediately if available, but fetch from network in the background and update cache.
  staleWhileRevalidate,
}
