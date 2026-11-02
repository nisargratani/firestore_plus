// Regression tests for the bugs fixed in 0.1.0 (QA report IDs FSP-01..11).
//
// Each test fails on 0.0.3 and passes on 0.1.0. They use FlakyFirestore
// (test/support/flaky_firestore.dart) to inject latency and Firestore errors
// into fake_cloud_firestore.
import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firestore_plus/firestore_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

import 'support/flaky_firestore.dart';

typedef Doc = Map<String, dynamic>;

const _cacheOnly = FirestoreOperationOptions(
  cachePolicy: CachePolicy.cacheOnly,
);
const _cacheFirst = FirestoreOperationOptions(
  cachePolicy: CachePolicy.cacheFirst,
);
const _networkOnly = FirestoreOperationOptions(
  cachePolicy: CachePolicy.networkOnly,
);
const _swr = FirestoreOperationOptions(
  cachePolicy: CachePolicy.staleWhileRevalidate,
);

const _fastRetry = RetryPolicy(
  maxAttempts: 3,
  initialDelay: Duration(milliseconds: 1),
  maxDelay: Duration(milliseconds: 5),
  jitter: false,
);

final class _Logs extends FirestorePlusLogger {
  final List<({FirestoreLogLevel level, String message, Object? error})>
      records = [];

  @override
  FirestoreLogLevel get logLevel => FirestoreLogLevel.debug;

  @override
  void log(FirestoreLogLevel level, String message,
      {Object? error, StackTrace? stackTrace}) {
    records.add((level: level, message: message, error: error));
  }

  Iterable<({FirestoreLogLevel level, String message, Object? error})> atLeast(
          FirestoreLogLevel level) =>
      records.where((r) => r.level.index >= level.index);
}

class _Metrics implements FirestoreMetricsListener {
  final List<FirestoreOperationMetrics> all = [];

  @override
  void onOperationComplete(FirestoreOperationMetrics metrics) =>
      all.add(metrics);
}

/// Records every key removed from the wrapped store.
class _SpyStore implements FirestoreCacheStore {
  _SpyStore(this.inner);

  final FirestoreCacheStore inner;
  final List<String> removes = [];

  @override
  Future<void> clear() => inner.clear();

  @override
  Future<void> clearCollection(String collection) =>
      inner.clearCollection(collection);

  @override
  Future<CacheEntry<Doc>?> get(String key) => inner.get(key);

  @override
  Future<void> put(String key, Doc value, {Duration? ttl}) =>
      inner.put(key, value, ttl: ttl);

  @override
  Future<void> remove(String key) {
    removes.add(key);
    return inner.remove(key);
  }
}

/// A fake backend with fault injection and a [FirestorePlus] on top of it.
class _Env {
  _Env({
    CachePolicy policy = CachePolicy.networkFirst,
    RetryPolicy retry = _fastRetry,
    Duration timeout = const Duration(seconds: 5),
    FirestoreCacheStore? store,
    FirestorePlusLogger? logger,
    FirestoreMetricsListener? metrics,
  })  : fake = FakeFirebaseFirestore(),
        plan = FaultPlan(),
        logs = logger is _Logs ? logger : _Logs() {
    plus = FirestorePlus(
      FlakyFirestore(fake, plan),
      config: FirestorePlusConfig(
        defaultCachePolicy: policy,
        defaultRetryPolicy: retry,
        defaultTimeout: timeout,
        cacheStore: store,
        logger: logger ?? logs,
        metricsListener: metrics,
      ),
    );
    users = plus.collection<Doc>(
      'users',
      fromFirestore: (data, _) => data,
      toFirestore: (doc) => doc,
    );
  }

  final FakeFirebaseFirestore fake;
  final FaultPlan plan;
  final _Logs logs;
  late final FirestorePlus plus;
  late final FirestoreCollection<Doc> users;

  Future<String?> name(String id, {FirestoreOperationOptions? options}) async =>
      (await users.getById(id, options: options))?['name'] as String?;

  FirestoreQuery<Doc> admins() =>
      users.query().where('role', isEqualTo: 'admin');

  Future<List<String>> adminNames({FirestoreOperationOptions? options}) async =>
      [for (final d in await admins().get(options: options)) d['name']];
}

Matcher _throwsType(FirestoreErrorType type) =>
    throwsA(isA<FirestorePlusException>().having((e) => e.type, 'type', type));

/// Starts [read] while [op] (`doc.get`, `query.get`) takes [latency]. The
/// fake backend computes the result when the request arrives, so the caller
/// gets data from that moment even if a write lands during the latency.
/// Await [_arrived] before writing.
Future<T> _slow<T>(FaultPlan plan, String op, Future<T> Function() read,
    {Duration latency = const Duration(milliseconds: 40)}) {
  plan.latency[op] = latency;
  return read();
}

/// Waits until a request started by [_slow] has reached the backend, then
/// removes the latency for later requests.
Future<void> _arrived(FaultPlan plan, String op) async {
  await Future<void>.delayed(const Duration(milliseconds: 5));
  plan.latency.remove(op);
}

void main() {
  test(
      'FSP-01: networkFirst must not serve cached data when the server '
      'rejects the read (permission-denied)', () async {
    final env = _Env(); // networkFirst
    await env.users.doc('a').set({'name': 'Private', 'role': 'admin'});
    expect(await env.name('a'), 'Private'); // cached now
    expect(await env.adminNames(), ['Private']); // cached now

    const rejections = {
      'permission-denied': FirestoreErrorType.permissionDenied,
      'not-found': FirestoreErrorType.notFound,
      'invalid-argument': FirestoreErrorType.invalidArgument,
      'failed-precondition': FirestoreErrorType.unknown,
    };
    for (final MapEntry(key: code, value: type) in rejections.entries) {
      env.plan.failAlways('doc.get', fbx(code));
      env.plan.failAlways('query.get', fbx(code));
      await expectLater(env.name('a'), _throwsType(type), reason: code);
      await expectLater(env.adminNames(), _throwsType(type), reason: code);
    }

    // Transient failures still fall back to the cache, and the fallback is
    // logged at warning level together with the error.
    env.plan.clear();
    env.logs.records.clear();
    env.plan.failAlways('doc.get', fbx('unavailable'));
    expect(await env.name('a'), 'Private');
    final fallback = env.logs
        .atLeast(FirestoreLogLevel.warning)
        .where((r) => r.message.contains('serving cached data'))
        .single;
    expect(fallback.message, startsWith('GET users/a'));
    expect(
        fallback.error,
        isA<FirestorePlusException>()
            .having((e) => e.type, 'type', FirestoreErrorType.unavailable));
  });

  test(
      'FSP-02: a read that is in flight while a write/clear() happens must '
      'not put pre-write data back into the cache', () async {
    final env = _Env();
    await env.users.doc('a').set({'name': 'Old', 'role': 'admin'});

    // Document read racing an update.
    var read = _slow(env.plan, 'doc.get', () => env.name('a'));
    await _arrived(env.plan, 'doc.get');
    await env.users.doc('a').update({'name': 'v1'});
    expect(await read, 'Old'); // the caller still gets its result
    expect(await env.name('a', options: _cacheFirst), 'v1',
        reason: 'document cache holds pre-write data');

    // Query read racing an update.
    final query = _slow(env.plan, 'query.get', () => env.adminNames());
    await _arrived(env.plan, 'query.get');
    await env.users.doc('a').update({'name': 'v2'});
    expect(await query, ['v1']);
    expect(await env.adminNames(options: _cacheFirst), ['v2'],
        reason: 'query cache holds pre-write data');

    // Explicit invalidation while a read is in flight.
    for (final invalidate in <Future<void> Function()>[
      () => env.plus.cache.invalidate('users/a'),
      () => env.plus.cache.invalidateCollection('users'),
      () => env.plus.cache.clear(), // e.g. on logout
    ]) {
      read = _slow(env.plan, 'doc.get', () => env.name('a'));
      await _arrived(env.plan, 'doc.get');
      await invalidate();
      await read;
      expect(await env.name('a', options: _cacheOnly), isNull,
          reason: 'cache repopulated after invalidation');
    }

    // A staleWhileRevalidate background refresh racing a write.
    await env.name('a', options: _networkOnly); // cache "v2"
    read = _slow(env.plan, 'doc.get', () => env.name('a', options: _swr));
    expect(await read, 'v2'); // served from cache, refresh still in flight
    await _arrived(env.plan, 'doc.get');
    await env.users.doc('a').update({'name': 'v3'});
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(await env.name('a', options: _cacheOnly), isNull,
        reason: 'background refresh re-cached pre-write data');

    // Reads that start after the write are still cached.
    expect(await env.name('a'), 'v3');
    expect(await env.name('a', options: _cacheOnly), 'v3');
  });

  test(
      'FSP-03: dependency constraints allow current FlutterFire '
      '(cloud_firestore 7.x, firebase_core 5.x)', () async {
    final pubspec = loadYaml(await File('pubspec.yaml').readAsString()) as Map;
    final deps = pubspec['dependencies'] as Map;
    VersionConstraint constraint(String name) =>
        VersionConstraint.parse(deps[name] as String);

    final firestore = constraint('cloud_firestore');
    final core = constraint('firebase_core');
    for (final v in ['6.8.0', '7.0.0', '7.1.0']) {
      expect(firestore.allows(Version.parse(v)), isTrue,
          reason: 'cloud_firestore $firestore must allow $v');
    }
    for (final v in ['4.13.0', '5.0.0', '5.1.0']) {
      expect(core.allows(Version.parse(v)), isTrue,
          reason: 'firebase_core $core must allow $v');
    }
  });

  test(
      'FSP-04: a read that starts after a write completed must not be '
      'deduplicated onto an older in-flight read', () async {
    final env = _Env();
    await env.users.doc('a').set({'name': 'Old'});

    final older = _slow(
        env.plan, 'doc.get', () => env.name('a', options: _networkOnly),
        latency: const Duration(milliseconds: 100));
    await _arrived(env.plan, 'doc.get');
    await env.users.doc('a').update({'name': 'New'}); // completed
    final newer = _slow(
        env.plan, 'doc.get', () => env.name('a', options: _networkOnly),
        latency: const Duration(milliseconds: 200));
    await _arrived(env.plan, 'doc.get');
    expect(await older, 'Old');

    // The older read finishing must not drop the newer read's dedupe entry:
    // a third identical read still joins the newer one.
    final third = env.name('a', options: _networkOnly);
    expect(await newer, 'New');
    expect(await third, 'New');
    expect(env.plan.count('doc.get'), 2);
  });

  test(
      'FSP-05: README retryIf example (checks FirestorePlusException) '
      'actually retries', () async {
    final seen = <Object>[];
    final env = _Env(
      retry: RetryPolicy(
        maxAttempts: 3,
        initialDelay: const Duration(milliseconds: 1),
        jitter: false,
        // Same shape as the README "Custom retry predicate" example.
        retryIf: (error) {
          seen.add(error);
          if (error is FirestorePlusException) {
            return error.type == FirestoreErrorType.unavailable;
          }
          return false;
        },
      ),
    );
    await env.users.doc('a').set({'name': 'A'});
    env.plan.failNext('doc.get', fbx('unavailable'), times: 2);

    expect(await env.name('a', options: _networkOnly), 'A');
    expect(env.plan.count('doc.get'), 3);
    expect(seen, hasLength(2));
    expect(
        seen.first,
        isA<FirestorePlusException>()
            .having((e) => e.originalException, 'originalException',
                isA<FirebaseException>())
            .having((e) => e.path, 'path', 'users/a')
            .having((e) => e.operation, 'operation', 'GET users/a'));
  });

  test(
      'FSP-06: a custom retryIf must not make writes retry timeouts '
      '(FieldValue.increment applied more than once)', () async {
    for (final retryIf in <bool Function(Object)>[
      ErrorMapper.isRetryable, // "same as the default rules"
      (_) => true, // retry everything
    ]) {
      final env = _Env(
        timeout: const Duration(milliseconds: 30),
        retry: RetryPolicy(
          maxAttempts: 3,
          initialDelay: const Duration(milliseconds: 1),
          jitter: false,
          retryIf: retryIf,
        ),
      );
      final counter = env.fake.doc('users/c');
      await counter.set({'n': 0});

      // The write commits on the server, but the client sees a timeout.
      for (var i = 0; i < 4; i++) {
        env.plan.script('doc.update',
            const Fault(applyFirst: true, delay: Duration(milliseconds: 100)));
      }
      await expectLater(
          env.users.doc('c').update({'n': FieldValue.increment(1)}),
          _throwsType(FirestoreErrorType.timeout));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect((await counter.get()).data()!['n'], 1);

      // Same for a server-side deadline-exceeded after the write applied.
      env.plan.clear();
      env.plan.script(
        'doc.update',
        Fault(applyFirst: true, error: fbx('deadline-exceeded')),
      );
      await expectLater(
          env.users.doc('c').update({'n': FieldValue.increment(1)}),
          _throwsType(FirestoreErrorType.timeout));
      expect((await counter.get()).data()!['n'], 2);

      // The custom predicate still decides for every other error.
      env.plan.failNext('doc.update', fbx('unavailable'));
      await env.users.doc('c').update({'n': FieldValue.increment(1)});
      expect((await counter.get()).data()!['n'], 3);
    }
  });

  test(
      'FSP-07: the default logger must not print query filter values '
      '(e.g. emails) when a read falls back to cache', () async {
    const email = 'alice@secret.example';
    final printed = <String>[];
    await runZoned(
      () async {
        final plan = FaultPlan();
        // Default config: ConsoleFirestoreLogger at info level.
        final plus = FirestorePlus(
          FlakyFirestore(FakeFirebaseFirestore(), plan),
          config: const FirestorePlusConfig(
            defaultRetryPolicy: RetryPolicy.none(),
          ),
        );
        final users = plus.collection<Doc>('users',
            fromFirestore: (d, _) => d, toFirestore: (d) => d);
        await users.doc('a').set({'email': email});
        final lookup = users.query().where('email', isEqualTo: email);

        await lookup.get(); // cached
        plan.failAlways('query.get', fbx('unavailable'));
        expect(await lookup.get(), hasLength(1)); // networkFirst fallback
        expect(await lookup.get(options: _swr), hasLength(1));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => printed.add(line),
      ),
    );
    final output = printed.join('\n');
    expect(output, contains('[WARNING] GET users'),
        reason: 'fallback and background failure should be logged');
    expect(output, contains('unavailable'), reason: 'the error is attached');
    expect(output, isNot(contains(email)));
  });

  test('FSP-08: metrics must not report a cacheOnly miss as served from cache',
      () async {
    final metrics = _Metrics();
    final env = _Env(metrics: metrics);
    expect(await env.name('missing', options: _cacheOnly), isNull);
    expect(metrics.all.last.servedFromCache, isFalse);

    await env.users.doc('a').set({'name': 'A'});
    await env.name('a');
    expect(await env.name('a', options: _cacheOnly), 'A');
    expect(metrics.all.last.servedFromCache, isTrue);
  });

  test(
      'FSP-09: staleWhileRevalidate must coalesce background refreshes '
      '(one in-flight refresh per key)', () async {
    final env = _Env(policy: CachePolicy.staleWhileRevalidate);
    await env.users.doc('a').set({'name': 'A'});
    await env.name('a'); // miss -> network
    env.plan.calls.clear();

    env.plan.latency['doc.get'] = const Duration(milliseconds: 30);
    for (var i = 0; i < 5; i++) {
      expect(await env.name('a'), 'A'); // hits while one refresh is pending
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(env.plan.count('doc.get'), 1);

    // Once the refresh has finished, the next hit starts a new one.
    await env.name('a');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(env.plan.count('doc.get'), 2);
  });

  test(
      'FSP-10: the query-key registry must stay bounded (a write must not '
      're-remove every query key ever issued)', () async {
    final spy = _SpyStore(MemoryCacheStore(maxSize: 10));
    final env = _Env(store: spy);
    FirestoreQuery<Doc> byEmail(int i) =>
        env.users.query().where('email', isEqualTo: 'u$i@example.com');

    for (var i = 0; i < 3000; i++) {
      await byEmail(i).get();
    }
    spy.removes.clear();
    await env.users.doc('z').set({'name': 'Z'});
    expect(spy.removes.length, lessThanOrEqualTo(1000),
        reason: 'one write issued ${spy.removes.length} removes');

    // A key dropped from tracking is also dropped from the store, so it can
    // never be served stale after a later write.
    final big = _Env(policy: CachePolicy.cacheFirst);
    FirestoreQuery<Doc> byAge(int i) =>
        big.users.query().where('age', isEqualTo: i);
    await big.users.doc('x').set({'age': 0});
    expect(await byAge(0).get(), hasLength(1));
    for (var i = 1; i <= 1000; i++) {
      await byAge(i).get();
    }
    await big.fake.doc('users/x').delete(); // not seen by the package
    expect(await byAge(0).get(options: _cacheOnly), isEmpty,
        reason: 'untracked query result is still cached');
    expect(await byAge(1000).get(options: _cacheOnly), isEmpty);
  });

  test(
      'FSP-11: toFirestore failures in batch.set / transaction set are '
      'normalized to serialization errors', () async {
    final env = _Env();
    final nums = env.plus.collection<int>(
      'nums',
      fromFirestore: (d, _) => d['v'] as int,
      toFirestore: (v) => v < 0 ? throw ArgumentError('neg') : {'v': v},
    );
    Matcher serialization(String operation) => throwsA(
        isA<FirestorePlusException>()
            .having((e) => e.type, 'type', FirestoreErrorType.serialization)
            .having((e) => e.path, 'path', 'nums/x')
            .having((e) => e.operation, 'operation', operation)
            .having((e) => e.originalException, 'originalException',
                isArgumentError));

    expect(() => env.plus.batch().set(nums.doc('x'), -1),
        serialization('BATCH SET nums/x'));
    await expectLater(
        env.plus.runTransaction((tx) async => tx.set(nums.doc('x'), -1)),
        serialization('TRANSACTION SET nums/x'));
  });
}
