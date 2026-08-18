import '../core/data_source.dart';

/// Represents an entry in the cache.
class CacheEntry<T> {
  /// The cached data.
  final T data;

  /// The time the entry was created.
  final DateTime createdAt;

  /// The time the entry expires.
  final DateTime? expiresAt;

  /// The source from which this data was originally obtained.
  final DataSource source;

  const CacheEntry({
    required this.data,
    required this.createdAt,
    this.expiresAt,
    this.source = DataSource.network,
  });

  /// Whether the cache entry has expired.
  bool get isStale => expiresAt != null && DateTime.now().isAfter(expiresAt!);
}

/// Abstract interface for a cache storage mechanism.
abstract interface class FirestoreCacheStore {
  /// Retrieves a cache entry by [key].
  Future<CacheEntry<Map<String, dynamic>>?> get(String key);

  /// Stores a [value] in the cache at [key], with an optional [ttl].
  Future<void> put(
    String key,
    Map<String, dynamic> value, {
    Duration? ttl,
  });

  /// Removes a specific [key] from the cache.
  Future<void> remove(String key);

  /// Clears all entries in the cache.
  Future<void> clear();

  /// Clears all entries related to a specific [collection].
  Future<void> clearCollection(String collection);
}
