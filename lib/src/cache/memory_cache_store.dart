import 'dart:collection';

import '../cache/cache_store.dart';

/// An in-memory implementation of [FirestoreCacheStore] with optional
/// LRU eviction when [maxSize] is exceeded.
///
/// Values are copied on write and on read, so callers mutating a returned
/// map cannot corrupt the cached entry.
class MemoryCacheStore implements FirestoreCacheStore {
  /// The maximum number of entries in the cache.
  ///
  /// When the cache exceeds this size, the oldest entries are evicted.
  /// Set to `0` to disable size limits (not recommended for production).
  final int maxSize;

  final LinkedHashMap<String, CacheEntry<Map<String, dynamic>>> _cache =
      LinkedHashMap();

  /// Creates a [MemoryCacheStore] with an optional [maxSize].
  ///
  /// Defaults to 500 entries.
  MemoryCacheStore({this.maxSize = 500});

  @override
  Future<void> clear() async {
    _cache.clear();
  }

  @override
  Future<void> clearCollection(String collection) async {
    final docPrefix = '$collection/';
    final queryPrefix = '$collection?';
    _cache.removeWhere((key, _) =>
        key == collection ||
        key.startsWith(docPrefix) ||
        key.startsWith(queryPrefix));
  }

  @override
  Future<CacheEntry<Map<String, dynamic>>?> get(String key) async {
    final entry = _cache[key];
    if (entry == null) return null;

    if (entry.isStale) {
      _cache.remove(key);
      return null;
    }

    // Move to end for LRU ordering
    _cache.remove(key);
    _cache[key] = entry;

    return CacheEntry(
      data: _deepCopy(entry.data),
      createdAt: entry.createdAt,
      expiresAt: entry.expiresAt,
      source: entry.source,
    );
  }

  @override
  Future<void> put(String key, Map<String, dynamic> value,
      {Duration? ttl}) async {
    final now = DateTime.now();
    DateTime? expiresAt;
    if (ttl != null) {
      expiresAt = now.add(ttl);
    }

    // Remove existing entry if present (to re-insert at the end)
    _cache.remove(key);

    _cache[key] = CacheEntry(
      data: _deepCopy(value),
      createdAt: now,
      expiresAt: expiresAt,
    );

    _evictIfNeeded();
  }

  @override
  Future<void> remove(String key) async {
    _cache.remove(key);
  }

  /// The current number of entries in the cache.
  int get length => _cache.length;

  static Map<String, dynamic> _deepCopy(Map<String, dynamic> map) =>
      map.map((k, v) => MapEntry(k, _copyValue(v)));

  static Object? _copyValue(Object? value) {
    if (value is Map<String, dynamic>) return _deepCopy(value);
    if (value is Map) {
      return value.map((k, v) => MapEntry(k, _copyValue(v)));
    }
    if (value is List) return value.map(_copyValue).toList();
    return value;
  }

  void _evictIfNeeded() {
    if (maxSize <= 0) return;
    while (_cache.length > maxSize) {
      _cache.remove(_cache.keys.first);
    }
  }
}
