import 'dart:async';

import 'package:meta/meta.dart';

import 'cache_policy.dart';
import 'cache_store.dart';
import '../core/data_source.dart';
import '../error/error_mapper.dart';
import '../logging/firestore_plus_logger.dart';

/// A read of one cache key that is in flight.
///
/// It is marked [invalidated] when that key is invalidated (by a write,
/// an `invalidate*` call or [CacheManager.clear]) before the read finishes,
/// so its result is known to predate the invalidation. Internal to the
/// package; created by [CacheManager.beginRead].
@internal
final class PendingRead {
  PendingRead._(this.cacheKey);

  /// The cache key being read.
  final String cacheKey;

  bool _invalidated = false;

  /// Whether [cacheKey] was invalidated after this read started.
  bool get invalidated => _invalidated;
}

/// Orchestrates cache read and write operations based on [CachePolicy].
///
/// Document entries are keyed by document path (`users/u1`). Query entries
/// are keyed by `<collectionPath>?q=<query>`.
class CacheManager {
  /// The maximum number of query keys tracked per collection for
  /// invalidation.
  ///
  /// When a collection has more distinct cached queries, the least recently
  /// used one stops being tracked and is removed from the cache store, so it
  /// can never be served after a write it would not see.
  static const int maxTrackedQueryKeysPerCollection = 500;

  final FirestoreCacheStore _store;
  final FirestorePlusLogger _logger;

  /// Query cache keys seen in this session, grouped by collection path, so
  /// they can be invalidated when a document in that collection is written.
  /// Each set is kept in least-recently-used order.
  final Map<String, Set<String>> _queryKeys = {};

  /// Reads in flight, per cache key.
  final Map<String, Set<PendingRead>> _pendingReads = {};

  /// Background refreshes (staleWhileRevalidate) in flight, per cache key.
  final Map<String, PendingRead> _revalidating = {};

  /// Creates a manager over a cache store. Every `FirestorePlus` creates its
  /// own, available as `FirestorePlus.cache`.
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
  ///
  /// A network result is not stored if [cacheKey] was invalidated while the
  /// read was in flight; it is still returned to the caller.
  Future<({Map<String, dynamic>? data, DataSource source})>
      getOrFetchWithSource({
    required String cacheKey,
    required CachePolicy policy,
    required Duration? ttl,
    required Future<Map<String, dynamic>?> Function() fetchFromNetwork,
    required String operationName,
  }) async {
    _trackQueryKey(cacheKey);
    final read = beginRead(cacheKey);
    try {
      return await _read(read, policy, ttl, fetchFromNetwork, operationName);
    } finally {
      endRead(read);
    }
  }

  Future<({Map<String, dynamic>? data, DataSource source})> _read(
    PendingRead read,
    CachePolicy policy,
    Duration? ttl,
    Future<Map<String, dynamic>?> Function() fetchFromNetwork,
    String operationName,
  ) async {
    final cacheKey = read.cacheKey;
    switch (policy) {
      case CachePolicy.networkOnly:
        _logger.debug('Cache Policy: networkOnly for $cacheKey');
        final data = await fetchFromNetwork();
        await _storeUnlessInvalidated(read, data, ttl);
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
        await _storeUnlessInvalidated(read, data, ttl);
        return (data: data, source: DataSource.network);

      case CachePolicy.networkFirst:
        _logger.debug('Cache Policy: networkFirst for $cacheKey');
        final Map<String, dynamic>? data;
        try {
          data = await fetchFromNetwork();
        } catch (e, st) {
          // Only transient failures (offline, unavailable, timeout, quota)
          // fall back. A rejection such as permission-denied must reach the
          // caller instead of being hidden behind cached data.
          if (!ErrorMapper.isRetryable(e)) rethrow;
          final entry = await _store.get(cacheKey);
          if (entry == null) rethrow;
          // Never log the cache key at warning level: query keys contain
          // filter values (e.g. e-mail addresses).
          _logger.warning(
              '$operationName failed with a transient error, '
              'serving cached data',
              error: e,
              stackTrace: st);
          _logger.debug('CACHE HIT (Fallback) for $cacheKey');
          return (data: entry.data, source: DataSource.cache);
        }
        await _storeUnlessInvalidated(read, data, ttl);
        return (data: data, source: DataSource.network);

      case CachePolicy.staleWhileRevalidate:
        _logger.debug('Cache Policy: staleWhileRevalidate for $cacheKey');
        final entry = await _store.get(cacheKey);
        if (entry != null) {
          _logger.debug('CACHE HIT for $cacheKey (revalidating in background)');
          _revalidate(cacheKey, ttl, fetchFromNetwork, operationName);
          return (data: entry.data, source: DataSource.staleCache);
        }

        // Nothing to serve: behave like a normal network read so errors
        // propagate instead of being reported as a missing document.
        _logger.debug('CACHE MISS for $cacheKey, fetching from network');
        final data = await fetchFromNetwork();
        await _storeUnlessInvalidated(read, data, ttl);
        return (data: data, source: DataSource.network);
    }
  }

  /// Starts a background refresh of [cacheKey], unless one that is still
  /// valid is already in flight. Errors cannot reach the caller; they are
  /// logged.
  void _revalidate(
    String cacheKey,
    Duration? ttl,
    Future<Map<String, dynamic>?> Function() fetchFromNetwork,
    String operationName,
  ) {
    final pending = _revalidating[cacheKey];
    if (pending != null && !pending.invalidated) {
      _logger.debug('Background refresh already in flight for $cacheKey');
      return;
    }
    final read = beginRead(cacheKey);
    _revalidating[cacheKey] = read;
    unawaited(
        _refresh(read, ttl, fetchFromNetwork, operationName).whenComplete(() {
      endRead(read);
      if (identical(_revalidating[cacheKey], read)) {
        _revalidating.remove(cacheKey);
      }
    }));
  }

  Future<void> _refresh(
    PendingRead read,
    Duration? ttl,
    Future<Map<String, dynamic>?> Function() fetchFromNetwork,
    String operationName,
  ) async {
    try {
      final data = await fetchFromNetwork();
      await _storeUnlessInvalidated(read, data, ttl);
      _logger.debug('Background fetch completed for ${read.cacheKey}');
    } catch (e, st) {
      _logger.warning('Background refresh for $operationName failed',
          error: e, stackTrace: st);
    }
  }

  /// Stores a network result for [read], unless its key was invalidated
  /// while the read was in flight (the result would be older than the write
  /// that caused the invalidation).
  Future<void> _storeUnlessInvalidated(
      PendingRead read, Map<String, dynamic>? data, Duration? ttl) {
    if (read.invalidated) {
      _logger.debug('Not caching ${read.cacheKey}: invalidated while the '
          'read was in flight');
      return Future.value();
    }
    return _storeResult(read.cacheKey, data, ttl);
  }

  /// Stores [data], or drops the entry when the network says it is gone so
  /// deleted documents are not served from cache later.
  Future<void> _storeResult(
      String cacheKey, Map<String, dynamic>? data, Duration? ttl) {
    if (data == null) return _store.remove(cacheKey);
    return _store.put(cacheKey, data, ttl: ttl);
  }

  /// Registers a read of [cacheKey] that is about to start. Pair every call
  /// with [endRead].
  @internal
  PendingRead beginRead(String cacheKey) {
    final read = PendingRead._(cacheKey);
    (_pendingReads[cacheKey] ??= <PendingRead>{}).add(read);
    return read;
  }

  /// Unregisters a read registered with [beginRead].
  @internal
  void endRead(PendingRead read) {
    final reads = _pendingReads[read.cacheKey];
    if (reads == null) return;
    reads.remove(read);
    if (reads.isEmpty) _pendingReads.remove(read.cacheKey);
  }

  /// Marks the in-flight reads of every key matching [test] as invalidated.
  void _invalidatePending(bool Function(String key) test) {
    for (final MapEntry(key: key, value: reads) in _pendingReads.entries) {
      if (!test(key)) continue;
      for (final read in reads) {
        read._invalidated = true;
      }
    }
  }

  void _trackQueryKey(String cacheKey) {
    final i = cacheKey.indexOf('?');
    if (i <= 0) return;
    final collection = cacheKey.substring(0, i);
    // Set literals are insertion-ordered: re-adding moves the key to the
    // most recently used end.
    final keys = _queryKeys[collection] ??= <String>{};
    keys
      ..remove(cacheKey)
      ..add(cacheKey);
    while (keys.length > maxTrackedQueryKeysPerCollection) {
      final oldest = keys.first;
      keys.remove(oldest);
      // An untracked entry would not be invalidated by later writes, so it
      // must not stay in the store.
      _invalidatePending((key) => key == oldest);
      unawaited(_store.remove(oldest).catchError((Object e, StackTrace st) {
        _logger.warning(
            'Could not evict an untracked query result of $collection',
            error: e,
            stackTrace: st);
      }));
    }
  }

  /// Clears a specific key from the cache.
  Future<void> invalidate(String key) {
    _invalidatePending((k) => k == key);
    return _store.remove(key);
  }

  /// Clears the cached document at [documentPath] and every cached query of
  /// its parent collection. Called automatically after writes.
  Future<void> invalidateDocument(String documentPath) async {
    final i = documentPath.lastIndexOf('/');
    final collection = i > 0 ? documentPath.substring(0, i) : null;
    // Mark synchronously, before any await, so a read finishing during the
    // removals below cannot store pre-write data.
    _invalidatePending((key) =>
        key == documentPath ||
        (collection != null && key.startsWith('$collection?')));
    await _store.remove(documentPath);
    if (collection != null) await invalidateQueries(collection);
  }

  /// Clears every cached query result of [collection], keeping cached
  /// documents.
  Future<void> invalidateQueries(String collection) async {
    final prefix = '$collection?';
    _invalidatePending((key) => key.startsWith(prefix));
    final keys = _queryKeys.remove(collection);
    if (keys == null) return;
    for (final key in keys) {
      await _store.remove(key);
    }
  }

  /// Clears an entire collection (documents and queries) from the cache.
  Future<void> invalidateCollection(String collection) async {
    final docPrefix = '$collection/';
    final queryPrefix = '$collection?';
    _invalidatePending((key) =>
        key == collection ||
        key.startsWith(docPrefix) ||
        key.startsWith(queryPrefix));
    await _store.clearCollection(collection);
    await invalidateQueries(collection);
  }

  /// Clears the entire cache.
  Future<void> clear() async {
    _invalidatePending((_) => true);
    _queryKeys.clear();
    await _store.clear();
  }
}
