import 'dart:async';

import 'cache_policy.dart';
import 'cache_store.dart';
import '../core/data_source.dart';
import '../logging/firestore_plus_logger.dart';

/// Orchestrates cache read and write operations based on [CachePolicy].
///
/// Document entries are keyed by document path (`users/u1`). Query entries
/// are keyed by `<collectionPath>?q=<query>`.
class CacheManager {
  final FirestoreCacheStore _store;
  final FirestorePlusLogger _logger;

  /// Query cache keys seen in this session, grouped by collection path, so
  /// they can be invalidated when a document in that collection is written.
  final Map<String, Set<String>> _queryKeys = {};

  CacheManager(this._store, this._logger);

  /// Executes an operation with caching logic applied.
  Future<Map<String, dynamic>?> getOrFetch({
    required String cacheKey,
    required CachePolicy policy,
    required Duration? ttl,
    required Future<Map<String, dynamic>?> Function() fetchFromNetwork,
    required String operationName,
  }) async {
    final result = await getOrFetchWithSource(
      cacheKey: cacheKey,
      policy: policy,
      ttl: ttl,
      fetchFromNetwork: fetchFromNetwork,
      operationName: operationName,
    );
    return result.data;
  }

  /// Like [getOrFetch], but also reports where the data came from.
  Future<({Map<String, dynamic>? data, DataSource source})>
      getOrFetchWithSource({
    required String cacheKey,
    required CachePolicy policy,
    required Duration? ttl,
    required Future<Map<String, dynamic>?> Function() fetchFromNetwork,
    required String operationName,
  }) async {
    _trackQueryKey(cacheKey);

    switch (policy) {
      case CachePolicy.networkOnly:
        _logger.debug('Cache Policy: networkOnly for $cacheKey');
        final data = await fetchFromNetwork();
        await _storeResult(cacheKey, data, ttl);
        return (data: data, source: DataSource.network);

      case CachePolicy.cacheOnly:
        _logger.debug('Cache Policy: cacheOnly for $cacheKey');
        final entry = await _store.get(cacheKey);
        if (entry != null) {
          _logger.debug('CACHE HIT for $cacheKey');
          return (data: entry.data, source: DataSource.cache);
        }
        _logger.debug('CACHE MISS for $cacheKey');
        return (data: null, source: DataSource.cache);

      case CachePolicy.cacheFirst:
        _logger.debug('Cache Policy: cacheFirst for $cacheKey');
        final entry = await _store.get(cacheKey);
        if (entry != null) {
          _logger.debug('CACHE HIT for $cacheKey');
          return (data: entry.data, source: DataSource.cache);
        }
        _logger.debug('CACHE MISS for $cacheKey, fetching from network');
        final data = await fetchFromNetwork();
        await _storeResult(cacheKey, data, ttl);
        return (data: data, source: DataSource.network);

      case CachePolicy.networkFirst:
        _logger.debug('Cache Policy: networkFirst for $cacheKey');
        try {
          final data = await fetchFromNetwork();
          await _storeResult(cacheKey, data, ttl);
          return (data: data, source: DataSource.network);
        } catch (e) {
          _logger.warning(
              'Network fetch failed for $cacheKey, falling back to cache');
          final entry = await _store.get(cacheKey);
          if (entry != null) {
            _logger.debug('CACHE HIT (Fallback) for $cacheKey');
            return (data: entry.data, source: DataSource.cache);
          }
          rethrow;
        }

      case CachePolicy.staleWhileRevalidate:
        _logger.debug('Cache Policy: staleWhileRevalidate for $cacheKey');
        final entry = await _store.get(cacheKey);
        if (entry != null) {
          _logger.debug('CACHE HIT for $cacheKey (revalidating in background)');
          // Background errors cannot reach the caller; they are logged.
          unawaited(fetchFromNetwork().then((data) async {
            await _storeResult(cacheKey, data, ttl);
            _logger.debug(
                'Background fetch completed and cache updated for $cacheKey');
          }).catchError((Object e) {
            _logger.warning('Background fetch failed for $cacheKey', error: e);
          }));
          return (data: entry.data, source: DataSource.staleCache);
        }

        // Nothing to serve: behave like a normal network read so errors
        // propagate instead of being reported as a missing document.
        _logger.debug('CACHE MISS for $cacheKey, fetching from network');
        final data = await fetchFromNetwork();
        await _storeResult(cacheKey, data, ttl);
        return (data: data, source: DataSource.network);
    }
  }

  /// Stores [data], or drops the entry when the network says it is gone so
  /// deleted documents are not served from cache later.
  Future<void> _storeResult(
      String cacheKey, Map<String, dynamic>? data, Duration? ttl) {
    if (data == null) return _store.remove(cacheKey);
    return _store.put(cacheKey, data, ttl: ttl);
  }

  void _trackQueryKey(String cacheKey) {
    final i = cacheKey.indexOf('?');
    if (i <= 0) return;
    (_queryKeys[cacheKey.substring(0, i)] ??= <String>{}).add(cacheKey);
  }

  /// Clears a specific key from the cache.
  Future<void> invalidate(String key) => _store.remove(key);

  /// Clears the cached document at [documentPath] and every cached query of
  /// its parent collection. Called automatically after writes.
  Future<void> invalidateDocument(String documentPath) async {
    await _store.remove(documentPath);
    final i = documentPath.lastIndexOf('/');
    if (i > 0) await invalidateQueries(documentPath.substring(0, i));
  }

  /// Clears every cached query result of [collection], keeping cached
  /// documents.
  Future<void> invalidateQueries(String collection) async {
    final keys = _queryKeys.remove(collection);
    if (keys == null) return;
    for (final key in keys) {
      await _store.remove(key);
    }
  }

  /// Clears an entire collection (documents and queries) from the cache.
  Future<void> invalidateCollection(String collection) async {
    await _store.clearCollection(collection);
    await invalidateQueries(collection);
  }

  /// Clears the entire cache.
  Future<void> clear() async {
    _queryKeys.clear();
    await _store.clear();
  }
}
