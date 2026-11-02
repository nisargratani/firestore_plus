// A fault-injecting wrapper around FakeFirebaseFirestore.
//
// firestore_plus only needs a `FirebaseFirestore`, so a delegating wrapper
// lets tests script FirebaseException codes, latency, "write applied but the
// client saw a failure", call counts and stream errors/cancellation.
//
// Copied from the firestore_plus QA tester app (firestore_plus_tester).
//
// ignore_for_file: subtype_of_sealed_class, must_be_immutable
// ignore_for_file: only_throw_errors, avoid_dynamic_calls
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';

/// One scripted behaviour for the next call of an operation.
class Fault {
  const Fault({this.error, this.applyFirst = false, this.delay});

  /// Error to throw (after [delay]).
  final Object? error;

  /// Run the real operation first (e.g. a write that commits but the client
  /// sees a timeout/unavailable).
  final bool applyFirst;

  /// Delay before throwing / returning.
  final Duration? delay;
}

FirebaseException fbx(String code, [String? message]) => FirebaseException(
      plugin: 'cloud_firestore',
      code: code,
      message: message ?? 'simulated $code',
    );

/// Operation names: doc.get, doc.set, doc.update, doc.delete, query.get,
/// count, batch.commit, transaction.
class FaultPlan {
  final Map<String, List<Fault>> _queue = {};
  final Map<String, Fault> _always = {};
  final Map<String, int> calls = {};

  /// Per-op latency. The result is computed at call time (like a server
  /// evaluating the request) and delivered after the latency.
  final Map<String, Duration> latency = {};

  /// Snapshot stream controllers per op ('doc.snapshots', 'query.snapshots').
  final Map<String, List<StreamController<Object>>> _streams = {};
  int streamCancels = 0;

  void failNext(String op, Object error, {int times = 1}) {
    for (var i = 0; i < times; i++) {
      (_queue[op] ??= []).add(Fault(error: error));
    }
  }

  void script(String op, Fault f) => (_queue[op] ??= []).add(f);

  void failAlways(String op, Object error) => _always[op] = Fault(error: error);

  void clear() {
    _queue.clear();
    _always.clear();
    latency.clear();
  }

  int count(String op) => calls[op] ?? 0;

  Future<T> run<T>(String op, Future<T> Function() body) async {
    calls[op] = count(op) + 1;
    final q = _queue[op];
    final fault = (q != null && q.isNotEmpty) ? q.removeAt(0) : _always[op];
    if (fault == null) {
      final result = await body();
      final lat = latency[op];
      if (lat != null) await Future<void>.delayed(lat);
      return result;
    }
    if (fault.applyFirst) {
      final result = await body();
      if (fault.delay != null) await Future<void>.delayed(fault.delay!);
      if (fault.error != null) throw fault.error!;
      return result;
    }
    if (fault.delay != null) await Future<void>.delayed(fault.delay!);
    if (fault.error != null) throw fault.error!;
    return body();
  }

  /// Push an error into every open snapshot stream of [op].
  void emitStreamError(String op, Object error) {
    for (final c in List.of(_streams[op] ?? const [])) {
      c.addError(error);
    }
  }

  Stream<S> wrapStream<S extends Object>(String op, Stream<S> inner) {
    late StreamController<S> c;
    StreamSubscription<S>? sub;
    c = StreamController<S>(
      onListen: () {
        (_streams[op] ??= []).add(c as StreamController<Object>);
        sub = inner.listen(c.add, onError: c.addError, onDone: c.close);
      },
      onCancel: () async {
        streamCancels++;
        _streams[op]?.remove(c);
        await sub?.cancel();
      },
    );
    return c.stream;
  }
}

class FlakyFirestore implements FirebaseFirestore {
  FlakyFirestore(this.inner, [FaultPlan? plan]) : plan = plan ?? FaultPlan();

  final FakeFirebaseFirestore inner;
  final FaultPlan plan;

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) =>
      FlakyCollection(this, inner.collection(collectionPath));

  @override
  WriteBatch batch() => FlakyBatch(this, inner.batch());

  @override
  Future<T> runTransaction<T>(
    TransactionHandler<T> transactionHandler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) =>
      plan.run(
        'transaction',
        () => inner.runTransaction(
          transactionHandler,
          timeout: timeout,
          maxAttempts: maxAttempts,
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FlakyBatch implements WriteBatch {
  FlakyBatch(this.fs, this.inner);
  final FlakyFirestore fs;
  final WriteBatch inner;

  @override
  Future<void> commit() => fs.plan.run('batch.commit', inner.commit);

  @override
  void set<T>(DocumentReference<T> document, T data, [SetOptions? options]) =>
      inner.set<T>(document, data, options);

  @override
  void update<T>(DocumentReference<T> document, T data) =>
      inner.update<T>(document, data);

  @override
  void delete(DocumentReference document) => inner.delete(document);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FlakyQuery implements Query<Map<String, dynamic>> {
  FlakyQuery(this.fs, this.innerQuery);
  final FlakyFirestore fs;
  final Query<Map<String, dynamic>> innerQuery;

  FaultPlan get plan => fs.plan;

  Query<Map<String, dynamic>> _w(Query<Map<String, dynamic>> q) =>
      FlakyQuery(fs, q);

  @override
  FirebaseFirestore get firestore => fs;

  @override
  Map<String, dynamic> get parameters => innerQuery.parameters;

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) =>
      plan.run('query.get', () => innerQuery.get(options));

  @override
  AggregateQuery count() => FlakyAggregate(fs, innerQuery.count());

  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) =>
      plan.wrapStream(
        'query.snapshots',
        innerQuery.snapshots(includeMetadataChanges: includeMetadataChanges),
      );

  @override
  Query<Map<String, dynamic>> limit(int limit) => _w(innerQuery.limit(limit));
  @override
  Query<Map<String, dynamic>> limitToLast(int limit) =>
      _w(innerQuery.limitToLast(limit));
  @override
  Query<Map<String, dynamic>> orderBy(
    Object field, {
    bool descending = false,
  }) =>
      _w(innerQuery.orderBy(field, descending: descending));
  @override
  Query<Map<String, dynamic>> startAfterDocument(DocumentSnapshot d) =>
      _w(innerQuery.startAfterDocument(d));
  @override
  Query<Map<String, dynamic>> startAtDocument(DocumentSnapshot d) =>
      _w(innerQuery.startAtDocument(d));
  @override
  Query<Map<String, dynamic>> endAtDocument(DocumentSnapshot d) =>
      _w(innerQuery.endAtDocument(d));
  @override
  Query<Map<String, dynamic>> endBeforeDocument(DocumentSnapshot d) =>
      _w(innerQuery.endBeforeDocument(d));
  @override
  Query<Map<String, dynamic>> startAfter(Iterable<Object?> v) =>
      _w(innerQuery.startAfter(v));
  @override
  Query<Map<String, dynamic>> startAt(Iterable<Object?> v) =>
      _w(innerQuery.startAt(v));
  @override
  Query<Map<String, dynamic>> endAt(Iterable<Object?> v) =>
      _w(innerQuery.endAt(v));
  @override
  Query<Map<String, dynamic>> endBefore(Iterable<Object?> v) =>
      _w(innerQuery.endBefore(v));

  @override
  Query<Map<String, dynamic>> where(
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
  }) =>
      _w(
        innerQuery.where(
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
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FlakyCollection extends FlakyQuery
    implements CollectionReference<Map<String, dynamic>> {
  FlakyCollection(FlakyFirestore fs, this.innerCol) : super(fs, innerCol);
  final CollectionReference<Map<String, dynamic>> innerCol;

  @override
  String get id => innerCol.id;
  @override
  String get path => innerCol.path;
  @override
  DocumentReference<Map<String, dynamic>>? get parent => innerCol.parent;

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      FlakyDoc(fs, innerCol.doc(path));

  @override
  Future<DocumentReference<Map<String, dynamic>>> add(
    Map<String, dynamic> data,
  ) =>
      plan.run('collection.add', () => innerCol.add(data));
}

class FlakyDoc implements DocumentReference<Map<String, dynamic>> {
  FlakyDoc(this.fs, this.innerDoc);
  final FlakyFirestore fs;
  final DocumentReference<Map<String, dynamic>> innerDoc;
  FaultPlan get plan => fs.plan;

  @override
  FirebaseFirestore get firestore => fs;
  @override
  String get id => innerDoc.id;
  @override
  String get path => innerDoc.path;

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) =>
      plan.run('doc.get', () => innerDoc.get(options));

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) =>
      plan.run('doc.set', () => innerDoc.set(data, options));

  @override
  Future<void> update(Map<Object, Object?> data) =>
      plan.run('doc.update', () => innerDoc.update(data));

  @override
  Future<void> delete() => plan.run('doc.delete', innerDoc.delete);

  @override
  Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) =>
      plan.wrapStream(
        'doc.snapshots',
        innerDoc.snapshots(includeMetadataChanges: includeMetadataChanges),
      );

  @override
  bool operator ==(Object other) =>
      other is DocumentReference && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FlakyAggregate implements AggregateQuery {
  FlakyAggregate(this.fs, this.inner);
  final FlakyFirestore fs;
  final AggregateQuery inner;

  @override
  Future<AggregateQuerySnapshot> get({
    AggregateSource source = AggregateSource.server,
  }) =>
      fs.plan.run('count', () => inner.get(source: source));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
