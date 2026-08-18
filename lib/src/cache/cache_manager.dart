import 'cache_policy.dart';
import 'cache_store.dart';
import '../logging/firestore_plus_logger.dart';

/// Orchestrates cache read and write operations based on [CachePolicy].
class CacheManager {
  final FirestoreCacheStore _store;
  final FirestorePlusLogger _logger;

  CacheManager(this._store, this._logger);

  /// Executes an operation with caching logic applied.
  Future<Map<String, dynamic>?> getOrFetch({
    required String cacheKey,
    required CachePolicy policy,
    required Duration? ttl,
    required Future<Map<String, dynamic>?> Function() fetchFromNetwork,
    required String operationName,
  }) async {
    switch (policy) {
      case CachePolicy.networkOnly:
        _logger.debug('Cache Policy: networkOnly for $cacheKey');
        final data = await fetchFromNetwork();
        if (data != null) {
          await _store.put(cacheKey, data, ttl: ttl);
        }
        return data;

      case CachePolicy.cacheOnly:
        _logger.debug('Cache Policy: cacheOnly for $cacheKey');
        final entry = await _store.get(cacheKey);
        if (entry != null) {
          _logger.debug('CACHE HIT for $cacheKey');
          return entry.data;
        } else {
          _logger.debug('CACHE MISS for $cacheKey');
          return null;
        }

      case CachePolicy.cacheFirst:
        _logger.debug('Cache Policy: cacheFirst for $cacheKey');
        final entry = await _store.get(cacheKey);
        if (entry != null) {
          _logger.debug('CACHE HIT for $cacheKey');
          return entry.data;
        }
        _logger.debug('CACHE MISS for $cacheKey, fetching from network');
        final data = await fetchFromNetwork();
        if (data != null) {
          await _store.put(cacheKey, data, ttl: ttl);
        }
        return data;

      case CachePolicy.networkFirst:
        _logger.debug('Cache Policy: networkFirst for $cacheKey');
        try {
          final data = await fetchFromNetwork();
          if (data != null) {
            await _store.put(cacheKey, data, ttl: ttl);
          }
          return data;
        } catch (e) {
          _logger.warning(
              'Network fetch failed for $cacheKey, falling back to cache');
          final entry = await _store.get(cacheKey);
          if (entry != null) {
            _logger.debug('CACHE HIT (Fallback) for $cacheKey');
            return entry.data;
          }
          rethrow;
        }

      case CachePolicy.staleWhileRevalidate:
        _logger.debug('Cache Policy: staleWhileRevalidate for $cacheKey');
        final entry = await _store.get(cacheKey);

        // Fire network request in the background
        final backgroundFetch = fetchFromNetwork().then((data) async {
          if (data != null) {
            await _store.put(cacheKey, data, ttl: ttl);
            _logger.debug(
                'Background fetch completed and cache updated for $cacheKey');
          }
        }).catchError((e) {
          _logger.warning('Background fetch failed for $cacheKey', error: e);
        });

        // We don't await the background fetch if we have a cache hit
        // Note: we can't easily bubble up background errors here to the user.
        // We'll just swallow it or log it.

        if (entry != null) {
          _logger.debug('CACHE HIT for $cacheKey (revalidating in background)');
          // To ensure tests complete cleanly or unhandled exceptions don't crash the app,
          // we consume the future
          unawaited(backgroundFetch);
          return entry.data;
        }

        _logger.debug('CACHE MISS for $cacheKey, waiting for background fetch');
        await backgroundFetch;
        final newEntry = await _store.get(cacheKey);
        return newEntry?.data;
    }
  }

  /// Clears a specific key from the cache.
  Future<void> invalidate(String key) => _store.remove(key);

  /// Clears an entire collection from the cache.
  Future<void> invalidateCollection(String collection) =>
      _store.clearCollection(collection);

  /// Clears the entire cache.
  Future<void> clear() => _store.clear();

  // Helper for unawaited
  void unawaited(Future<void>? future) {}
}
