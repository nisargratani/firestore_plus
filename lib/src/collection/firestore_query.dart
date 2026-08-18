import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/firestore_operation_options.dart';
import '../core/firestore_plus.dart';
import '../error/error_mapper.dart';
import '../error/firestore_plus_exception.dart';
import '../metrics/firestore_metrics.dart';
import '../pagination/pagination.dart';

/// A typed wrapper for building and executing Firestore queries.
class FirestoreQuery<T> {
  /// The native Firestore query.
  final Query nativeQuery;

  /// The [FirestorePlus] instance.
  final FirestorePlus firestore;

  /// The deserialization mapper.
  final T Function(Map<String, dynamic> data, String id) fromFirestore;

  /// The original collection path (used for caching scope).
  final String collectionPath;

  /// A representation of the query constraints used to generate cache keys.
  final String _queryId;

  FirestoreQuery({
    required this.nativeQuery,
    required this.firestore,
    required this.fromFirestore,
    required this.collectionPath,
    String? queryId,
  }) : _queryId = queryId ?? 'all';

  /// Internal cache key generator.
  String get _cacheKey => '$collectionPath?q=$_queryId';

  /// Appends a string to the query ID.
  String _appendQueryId(String segment) => '$_queryId&$segment';

  FirestoreQuery<T> _cloneWith(Query query, String segment) {
    return FirestoreQuery<T>(
      nativeQuery: query,
      firestore: firestore,
      fromFirestore: fromFirestore,
      collectionPath: collectionPath,
      queryId: _appendQueryId(segment),
    );
  }

  /// Limits the number of documents returned.
  FirestoreQuery<T> limit(int limit) {
    return _cloneWith(nativeQuery.limit(limit), 'l=$limit');
  }

  /// Limits the number of documents returned to the last [limit] documents.
  FirestoreQuery<T> limitToLast(int limit) {
    return _cloneWith(nativeQuery.limitToLast(limit), 'lLast=$limit');
  }

  /// Orders the documents by [field].
  FirestoreQuery<T> orderBy(Object field, {bool descending = false}) {
    return _cloneWith(nativeQuery.orderBy(field, descending: descending),
        'o=$field,d=$descending');
  }

  /// Starts at the given [document] snapshot.
  FirestoreQuery<T> startAtDocument(DocumentSnapshot document) {
    return _cloneWith(
        nativeQuery.startAtDocument(document), 'saDoc=${document.id}');
  }

  /// Starts after the given [document] snapshot.
  FirestoreQuery<T> startAfterDocument(DocumentSnapshot document) {
    return _cloneWith(
        nativeQuery.startAfterDocument(document), 'saftDoc=${document.id}');
  }

  /// Ends at the given [document] snapshot.
  FirestoreQuery<T> endAtDocument(DocumentSnapshot document) {
    return _cloneWith(
        nativeQuery.endAtDocument(document), 'eaDoc=${document.id}');
  }

  /// Ends before the given [document] snapshot.
  FirestoreQuery<T> endBeforeDocument(DocumentSnapshot document) {
    return _cloneWith(
        nativeQuery.endBeforeDocument(document), 'ebDoc=${document.id}');
  }

  /// Starts at the given [values].
  FirestoreQuery<T> startAt(Iterable<Object?> values) {
    return _cloneWith(
        nativeQuery.startAt(values), 'saVals=${values.join(',')}');
  }

  /// Starts after the given [values].
  FirestoreQuery<T> startAfter(Iterable<Object?> values) {
    return _cloneWith(
        nativeQuery.startAfter(values), 'saftVals=${values.join(',')}');
  }

  /// Ends at the given [values].
  FirestoreQuery<T> endAt(Iterable<Object?> values) {
    return _cloneWith(nativeQuery.endAt(values), 'eaVals=${values.join(',')}');
  }

  /// Ends before the given [values].
  FirestoreQuery<T> endBefore(Iterable<Object?> values) {
    return _cloneWith(
        nativeQuery.endBefore(values), 'ebVals=${values.join(',')}');
  }

  /// Filters by the given [field].
  FirestoreQuery<T> where(
    Object field, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? arrayContains,
    Iterable<Object?>? arrayContainsAny,
    Iterable<Object?>? whereIn,
    Iterable<Object?>? whereNotIn,
    bool? isNull,
  }) {
    final segment =
        'w=$field:eq=$isEqualTo:neq=$isNotEqualTo:lt=$isLessThan:lte=$isLessThanOrEqualTo:gt=$isGreaterThan:gte=$isGreaterThanOrEqualTo:ac=$arrayContains:aca=$arrayContainsAny:wi=$whereIn:wni=$whereNotIn:n=$isNull';
    return _cloneWith(
      nativeQuery.where(
        field,
        isEqualTo: isEqualTo,
        isNotEqualTo: isNotEqualTo,
        isLessThan: isLessThan,
        isLessThanOrEqualTo: isLessThanOrEqualTo,
        isGreaterThan: isGreaterThan,
        isGreaterThanOrEqualTo: isGreaterThanOrEqualTo,
        arrayContains: arrayContains,
        arrayContainsAny: arrayContainsAny,
        whereIn: whereIn,
        whereNotIn: whereNotIn,
        isNull: isNull,
      ),
      segment,
    );
  }

  /// Executes the query and returns a list of results.
  Future<List<T>> get({FirestoreOperationOptions? options}) async {
    final rawData = await firestore.executor.executeRead(
      path: collectionPath,
      cacheKey: _cacheKey,
      options: options,
      fetchFromNetwork: () async {
        final snap = await nativeQuery.get();
        final docs = snap.docs
            .map((doc) =>
                {'__id__': doc.id, ...doc.data() as Map<String, dynamic>})
            .toList();
        return {'docs': docs};
      },
    );

    if (rawData == null || rawData['docs'] == null) return [];

    final docs = rawData['docs'] as List<dynamic>;
    return _mapDocs(docs);
  }

  /// Executes the query with pagination.
  /// Note: Pagination cursors are dynamically fetched, so caching is typically disabled
  /// or requires careful networkFirst/networkOnly policies to avoid stale cursors.
  Future<PaginatedResult<T>> paginate({
    required int limit,
    PaginationCursor? startAfter,
    FirestoreOperationOptions? options,
  }) async {
    Query q = nativeQuery.limit(limit);
    if (startAfter != null) {
      q = q.startAfterDocument(startAfter.document);
    }

    // Force network only or similar for pagination? We leave it up to the user,
    // but the cacheKey needs to be unique for the cursor.
    final cursorId = startAfter?.document.id ?? 'start';
    final pageCacheKey = '$_cacheKey&l=$limit&saDoc=$cursorId';

    final rawData = await firestore.executor.executeRead(
      path: collectionPath,
      cacheKey: pageCacheKey,
      options: options,
      fetchFromNetwork: () async {
        final snap = await q.get();
        final docs = snap.docs
            .map((doc) =>
                {'__id__': doc.id, ...doc.data() as Map<String, dynamic>})
            .toList();

        // We cannot easily serialize the DocumentSnapshot into the map for Cache,
        // so caching pagination is technically very difficult.
        // We won't cache the snapshot, but we can return the native snapshot ID and
        // the user has to handle it or we fetch the doc again.
        // Actually, returning the snapshot inside the map will fail caching if the cache doesn't support it.
        // For our memory cache, it's fine, but not for others.

        // Return a special wrapper that we use internally for parsing
        return {
          'docs': docs,
          // Store the actual snapshot object in memory only temporarily if possible,
          // or we just return it out-of-band.
          '_lastSnap': snap.docs.isNotEmpty ? snap.docs.last : null,
        };
      },
    );

    if (rawData == null || rawData['docs'] == null) {
      return PaginatedResult<T>(items: [], hasMore: false);
    }

    final docs = rawData['docs'] as List<dynamic>;
    final items = _mapDocs(docs);

    // We get the last snap from rawData if available
    final lastSnap = rawData['_lastSnap'] as DocumentSnapshot?;

    return PaginatedResult<T>(
      items: items,
      hasMore: items.length >= limit,
      cursor: lastSnap != null ? PaginationCursor(lastSnap) : null,
    );
  }

  /// Counts the documents matching the query.
  Future<int> count({FirestoreOperationOptions? options}) async {
    int count = 0;
    await firestore.executor.executeWrite(
      // Reusing executeWrite because count is not cached by CacheManager natively easily
      path: collectionPath,
      type: FirestoreOperationType.count,
      options: options,
      operation: () async {
        final aggregate = await nativeQuery.count().get();
        count = aggregate.count ?? 0;
      },
    );
    return count;
  }

  /// A typed stream of query snapshots.
  Stream<List<T>> snapshots() {
    return nativeQuery.snapshots().map((snap) {
      return snap.docs.map((doc) {
        try {
          return fromFirestore(doc.data() as Map<String, dynamic>, doc.id);
        } catch (e, st) {
          firestore.config.logger.error(
              'Failed to deserialize stream query doc: $e',
              error: e,
              stackTrace: st);
          throw ErrorMapper.map(
            FirestorePlusException(
              type: FirestoreErrorType.serialization,
              message: 'Failed to deserialize document stream: $e',
              originalException: e,
              stackTrace: st,
              operation: 'STREAM GET $collectionPath',
              path: '$collectionPath/${doc.id}',
            ),
          );
        }
      }).toList();
    });
  }

  List<T> _mapDocs(List<dynamic> docs) {
    final List<T> results = [];
    for (final doc in docs) {
      final map = doc as Map<String, dynamic>;
      final id = map['__id__'] as String;

      // Make a copy to prevent mutation issues and remove __id__
      final data = Map<String, dynamic>.from(map)..remove('__id__');

      try {
        results.add(fromFirestore(data, id));
      } catch (e, st) {
        throw ErrorMapper.map(
          FirestorePlusException(
            type: FirestoreErrorType.serialization,
            message: 'Failed to deserialize document from query: $e',
            originalException: e,
            stackTrace: st,
            operation: 'GET $collectionPath',
            path: '$collectionPath/$id',
          ),
        );
      }
    }
    return results;
  }
}
