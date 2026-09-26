import 'dart:async';
import 'dart:convert';

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

  /// Canonical, collision-free encoding of a query value for cache keys.
  static String _enc(Object? v) {
    if (v == null) return 'null';
    if (v is String) return jsonEncode(v);
    if (v is num || v is bool) return '$v';
    if (v is Filter) return 'filter:${_enc(v.toJson())}';
    if (v is FieldPath) return 'path:${_enc(v.components)}';
    if (v is DocumentReference) return 'ref:${jsonEncode(v.path)}';
    if (v is Timestamp) return 'ts:${v.seconds}.${v.nanoseconds}';
    if (v is DateTime) return 'dt:${v.toUtc().toIso8601String()}';
    if (v is GeoPoint) return 'geo:${v.latitude},${v.longitude}';
    if (v is Blob) return 'blob:${base64Encode(v.bytes)}';
    if (v is Map) {
      final entries = v.entries
          .map((e) => '${_enc(e.key.toString())}:${_enc(e.value)}')
          .toList()
        ..sort();
      return '{${entries.join(',')}}';
    }
    if (v is Iterable) return '[${v.map(_enc).join(',')}]';
    return jsonEncode(v.toString());
  }

  /// Creates a typed query. Usually obtained from
  /// `FirestoreCollection.query` rather than constructed directly.
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
        'o=${_enc(field)},d=$descending');
  }

  /// Starts at the given [document] snapshot.
  FirestoreQuery<T> startAtDocument(DocumentSnapshot document) {
    return _cloneWith(nativeQuery.startAtDocument(document),
        'saDoc=${_enc(document.reference.path)}');
  }

  /// Starts after the given [document] snapshot.
  FirestoreQuery<T> startAfterDocument(DocumentSnapshot document) {
    return _cloneWith(nativeQuery.startAfterDocument(document),
        'saftDoc=${_enc(document.reference.path)}');
  }

  /// Ends at the given [document] snapshot.
  FirestoreQuery<T> endAtDocument(DocumentSnapshot document) {
    return _cloneWith(nativeQuery.endAtDocument(document),
        'eaDoc=${_enc(document.reference.path)}');
  }

  /// Ends before the given [document] snapshot.
  FirestoreQuery<T> endBeforeDocument(DocumentSnapshot document) {
    return _cloneWith(nativeQuery.endBeforeDocument(document),
        'ebDoc=${_enc(document.reference.path)}');
  }

  /// Starts at the given [values].
  FirestoreQuery<T> startAt(Iterable<Object?> values) {
    return _cloneWith(nativeQuery.startAt(values), 'saVals=${_enc(values)}');
  }

  /// Starts after the given [values].
  FirestoreQuery<T> startAfter(Iterable<Object?> values) {
    return _cloneWith(
        nativeQuery.startAfter(values), 'saftVals=${_enc(values)}');
  }

  /// Ends at the given [values].
  FirestoreQuery<T> endAt(Iterable<Object?> values) {
    return _cloneWith(nativeQuery.endAt(values), 'eaVals=${_enc(values)}');
  }

  /// Ends before the given [values].
  FirestoreQuery<T> endBefore(Iterable<Object?> values) {
    return _cloneWith(nativeQuery.endBefore(values), 'ebVals=${_enc(values)}');
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
    final ops = <String, Object?>{
      'eq': isEqualTo,
      'neq': isNotEqualTo,
      'lt': isLessThan,
      'lte': isLessThanOrEqualTo,
      'gt': isGreaterThan,
      'gte': isGreaterThanOrEqualTo,
      'ac': arrayContains,
      'aca': arrayContainsAny,
      'wi': whereIn,
      'wni': whereNotIn,
      'n': isNull,
    }..removeWhere((_, v) => v == null);
    final segment = 'w=${_enc(field)}:${_enc(ops)}';
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
      type: FirestoreOperationType.query,
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
  ///
  /// Fetches `limit + 1` documents so [PaginatedResult.hasMore] is exact.
  /// Cached pages hold plain document data only; when a page is served from
  /// cache, the cursor is rebuilt by reading the last document's snapshot.
  Future<PaginatedResult<T>> paginate({
    required int limit,
    PaginationCursor? startAfter,
    FirestoreOperationOptions? options,
  }) async {
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'must be greater than 0');
    }
    // Cursor before limit: equivalent in Firestore, and fakes that apply
    // constraints in call order behave correctly too.
    Query q = nativeQuery;
    if (startAfter != null) {
      q = q.startAfterDocument(startAfter.document);
    }
    q = q.limit(limit + 1);

    final cursorPath = startAfter?.document.reference.path;
    final pageCacheKey =
        '$_cacheKey&page=$limit&after=${_enc(cursorPath ?? 'start')}';

    DocumentSnapshot? lastSnap;
    final rawData = await firestore.executor.executeRead(
      path: collectionPath,
      type: FirestoreOperationType.query,
      cacheKey: pageCacheKey,
      options: options,
      fetchFromNetwork: () async {
        final snap = await q.get();
        final pageDocs = snap.docs.take(limit).toList();
        lastSnap = pageDocs.isNotEmpty ? pageDocs.last : null;
        return {
          'docs': [
            for (final doc in pageDocs)
              {'__id__': doc.id, ...doc.data() as Map<String, dynamic>},
          ],
          'hasMore': snap.docs.length > limit,
        };
      },
    );

    if (rawData == null || rawData['docs'] == null) {
      return PaginatedResult<T>(items: [], hasMore: false);
    }

    final docs = rawData['docs'] as List<dynamic>;
    final items = _mapDocs(docs);
    final hasMore = rawData['hasMore'] as bool? ?? items.length >= limit;

    if (lastSnap == null && docs.isNotEmpty) {
      final lastId = (docs.last as Map)['__id__'] as String;
      lastSnap = await _snapshotForCursor(lastId);
    }

    return PaginatedResult<T>(
      items: items,
      hasMore: hasMore,
      cursor: lastSnap != null ? PaginationCursor(lastSnap!) : null,
    );
  }

  /// Reads the snapshot for a cached page's last document, preferring the
  /// Firestore local cache. Returns null if it cannot be read.
  Future<DocumentSnapshot?> _snapshotForCursor(String id) async {
    final ref = nativeQuery.firestore.collection(collectionPath).doc(id);
    try {
      final snap = await ref.get(const GetOptions(source: Source.cache));
      if (snap.exists) return snap;
    } catch (_) {
      // Not in the local cache or unsupported; fall back to the server.
    }
    try {
      final snap = await ref.get();
      return snap.exists ? snap : null;
    } catch (e) {
      firestore.config.logger
          .warning('Could not rebuild pagination cursor for $id', error: e);
      return null;
    }
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
  ///
  /// Errors (including deserialization failures) are emitted as
  /// [FirestorePlusException].
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
    }).transform(StreamTransformer<List<T>, List<T>>.fromHandlers(
        handleError: (e, st, sink) {
      sink.addError(
          ErrorMapper.map(e, st, 'STREAM GET $collectionPath', collectionPath),
          st);
    }));
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
