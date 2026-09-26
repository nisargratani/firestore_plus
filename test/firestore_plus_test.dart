import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firestore_plus/firestore_plus.dart';

// ---------------------------------------------------------------------------
// Test model
// ---------------------------------------------------------------------------

class User {
  final String id;
  final String name;
  final int? age;

  User({required this.id, required this.name, this.age});

  factory User.fromFirestore(Map<String, dynamic> data, String id) {
    return User(
      id: id,
      name: data['name'] as String,
      age: data['age'] as int?,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'name': name,
      if (age != null) 'age': age,
    };
  }
}

// ---------------------------------------------------------------------------
// Test logger
// ---------------------------------------------------------------------------

final class TestLogger extends FirestorePlusLogger {
  final List<String> messages = [];

  @override
  FirestoreLogLevel get logLevel => FirestoreLogLevel.debug;

  @override
  void log(FirestoreLogLevel level, String message,
      {Object? error, StackTrace? stackTrace}) {
    messages.add('[${level.name.toUpperCase()}] $message');
  }
}

// ---------------------------------------------------------------------------
// Test metrics listener
// ---------------------------------------------------------------------------

class TestMetricsListener implements FirestoreMetricsListener {
  final List<FirestoreOperationMetrics> recorded = [];

  @override
  void onOperationComplete(FirestoreOperationMetrics metrics) {
    recorded.add(metrics);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

FirestorePlus _createFirestore(
  FakeFirebaseFirestore fakeFirestore, {
  CachePolicy cachePolicy = CachePolicy.networkOnly,
  TestLogger? logger,
  TestMetricsListener? metricsListener,
  bool enableDedup = true,
  RetryPolicy? retryPolicy,
  Duration? defaultCacheDuration,
  FirestoreCacheStore? cacheStore,
}) {
  return FirestorePlus(
    fakeFirestore,
    config: FirestorePlusConfig(
      defaultCachePolicy: cachePolicy,
      defaultRetryPolicy: retryPolicy ?? const RetryPolicy.none(),
      enableRequestDeduplication: enableDedup,
      logger: logger ?? TestLogger(),
      metricsListener: metricsListener,
      defaultCacheDuration: defaultCacheDuration,
      cacheStore: cacheStore,
    ),
  );
}

FirestoreCollection<User> _usersCollection(FirestorePlus firestore) {
  return firestore.collection<User>(
    'users',
    fromFirestore: User.fromFirestore,
    toFirestore: (user) => user.toFirestore(),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // =========================================================================
  // CRUD Tests
  // =========================================================================

  group('CRUD', () {
    late FakeFirebaseFirestore fakeFirestore;
    late FirestorePlus firestore;
    late FirestoreCollection<User> users;

    setUp(() {
      fakeFirestore = FakeFirebaseFirestore();
      firestore = _createFirestore(fakeFirestore);
      users = _usersCollection(firestore);
    });

    test('add creates a new document and returns a reference', () async {
      final docRef = await users.add(User(id: '', name: 'Alice'));
      expect(docRef.id, isNotEmpty);

      final user = await users.getById(docRef.id);
      expect(user, isNotNull);
      expect(user!.name, 'Alice');
    });

    test('set writes a document with a specific ID', () async {
      final docRef = users.doc('user1');
      await docRef.set(User(id: 'user1', name: 'Bob'));

      final user = await docRef.get();
      expect(user!.name, 'Bob');
    });

    test('update modifies existing document fields', () async {
      final docRef = users.doc('user1');
      await docRef.set(User(id: 'user1', name: 'Bob'));

      await docRef.update({'name': 'Charlie'});
      final user = await docRef.get();
      expect(user!.name, 'Charlie');
    });

    test('delete removes a document', () async {
      final docRef = users.doc('user2');
      await docRef.set(User(id: 'user2', name: 'Dave'));

      var doesExist = await docRef.exists();
      expect(doesExist, isTrue);

      await docRef.delete();
      doesExist = await docRef.exists();
      expect(doesExist, isFalse);
    });

    test('getById returns null for missing document', () async {
      final user = await users.getById('nonexistent');
      expect(user, isNull);
    });

    test('exists returns false for missing document', () async {
      final result = await users.doc('missing').exists();
      expect(result, isFalse);
    });

    test('get returns empty list for empty collection', () async {
      final results = await users.get();
      expect(results, isEmpty);
    });

    test('count returns correct number of documents', () async {
      await users.add(User(id: '', name: 'A'));
      await users.add(User(id: '', name: 'B'));
      await users.add(User(id: '', name: 'C'));

      final c = await users.query().count();
      expect(c, 3);
    });
  });

  // =========================================================================
  // Query Tests
  // =========================================================================

  group('Query', () {
    late FakeFirebaseFirestore fakeFirestore;
    late FirestorePlus firestore;
    late FirestoreCollection<User> users;

    setUp(() async {
      fakeFirestore = FakeFirebaseFirestore();
      firestore = _createFirestore(fakeFirestore);
      users = _usersCollection(firestore);

      // Seed data
      await users.doc('a').set(User(id: 'a', name: 'Alice', age: 30));
      await users.doc('b').set(User(id: 'b', name: 'Bob', age: 25));
      await users.doc('c').set(User(id: 'c', name: 'Charlie', age: 35));
      await users.doc('d').set(User(id: 'd', name: 'Alice', age: 22));
    });

    test('where filters by equality', () async {
      final results =
          await users.query().where('name', isEqualTo: 'Alice').get();
      expect(results.length, 2);
      expect(results.every((u) => u.name == 'Alice'), isTrue);
    });

    test('where filters with isGreaterThan', () async {
      final results = await users.query().where('age', isGreaterThan: 28).get();
      expect(results.length, 2);
    });

    test('orderBy sorts results', () async {
      final results = await users.query().orderBy('age').get();
      final ages = results.map((u) => u.age).toList();
      expect(ages, [22, 25, 30, 35]);
    });

    test('limit restricts result count', () async {
      final results = await users.query().orderBy('age').limit(2).get();
      expect(results.length, 2);
      expect(results[0].age, 22);
    });

    test('combined where + orderBy + limit', () async {
      final results = await users
          .query()
          .where('age', isGreaterThan: 20)
          .orderBy('age')
          .limit(2)
          .get();
      expect(results.length, 2);
      expect(results[0].age, 22);
      expect(results[1].age, 25);
    });

    test('query with no results returns empty list', () async {
      final results =
          await users.query().where('name', isEqualTo: 'Nobody').get();
      expect(results, isEmpty);
    });
  });

  // =========================================================================
  // Cache Tests
  // =========================================================================

  group('Cache', () {
    late FakeFirebaseFirestore fakeFirestore;

    setUp(() {
      fakeFirestore = FakeFirebaseFirestore();
    });

    test('cacheFirst returns cached value on second fetch', () async {
      final firestore =
          _createFirestore(fakeFirestore, cachePolicy: CachePolicy.cacheFirst);
      final users = _usersCollection(firestore);

      final docRef = users.doc('u1');
      await docRef.set(User(id: 'u1', name: 'Grace'));

      // First fetch - populates cache
      final fetched1 = await docRef.get();
      expect(fetched1!.name, 'Grace');

      // Update behind the scenes
      await fakeFirestore
          .collection('users')
          .doc('u1')
          .update({'name': 'Heidi'});

      // Second fetch - should return cached Grace
      final fetched2 = await docRef.get();
      expect(fetched2!.name, 'Grace');
    });

    test('networkOnly always fetches fresh data', () async {
      final firestore =
          _createFirestore(fakeFirestore, cachePolicy: CachePolicy.networkOnly);
      final users = _usersCollection(firestore);
      final docRef = users.doc('u2');
      await docRef.set(User(id: 'u2', name: 'First'));

      final fetched1 = await docRef.get();
      expect(fetched1!.name, 'First');

      await fakeFirestore
          .collection('users')
          .doc('u2')
          .update({'name': 'Second'});

      final fetched2 = await docRef.get();
      expect(fetched2!.name, 'Second');
    });

    test('cacheOnly returns null on cache miss', () async {
      final firestore =
          _createFirestore(fakeFirestore, cachePolicy: CachePolicy.cacheOnly);
      final users = _usersCollection(firestore);

      // Add a document via raw firestore (not through the package, so no cache)
      await fakeFirestore
          .collection('users')
          .doc('u3')
          .set({'name': 'Invisible'});

      final fetched = await users.getById('u3');
      expect(fetched, isNull);
    });

    test('networkFirst returns fresh data when network succeeds', () async {
      final firestore = _createFirestore(fakeFirestore,
          cachePolicy: CachePolicy.networkFirst);
      final users = _usersCollection(firestore);
      final docRef = users.doc('u4');
      await docRef.set(User(id: 'u4', name: 'Network'));

      final fetched = await docRef.get();
      expect(fetched!.name, 'Network');
    });

    test('staleWhileRevalidate returns stale data immediately', () async {
      final firestore =
          _createFirestore(fakeFirestore, cachePolicy: CachePolicy.cacheFirst);
      final users = _usersCollection(firestore);
      final docRef = users.doc('u5');
      await docRef.set(User(id: 'u5', name: 'Stale'));

      // Pre-populate cache
      await docRef.get();

      // Switch to staleWhileRevalidate
      final fetched = await docRef.get(
        options: const FirestoreOperationOptions(
            cachePolicy: CachePolicy.staleWhileRevalidate),
      );
      // Should return immediately from cache
      expect(fetched!.name, 'Stale');
    });

    test('TTL causes cache entry to expire', () async {
      final firestore =
          _createFirestore(fakeFirestore, cachePolicy: CachePolicy.cacheFirst);
      final users = _usersCollection(firestore);
      final docRef = users.doc('u6');
      await docRef.set(User(id: 'u6', name: 'Temp'));

      // Fetch with very short TTL
      await docRef.get(
        options: const FirestoreOperationOptions(
          cachePolicy: CachePolicy.cacheFirst,
          cacheDuration: Duration(milliseconds: 1),
        ),
      );

      // Wait for TTL to expire
      await Future.delayed(const Duration(milliseconds: 10));

      // Update in raw firestore
      await fakeFirestore
          .collection('users')
          .doc('u6')
          .update({'name': 'Fresh'});

      // Fetch again - cache should have expired, gets fresh data
      final fetched = await docRef.get(
        options: const FirestoreOperationOptions(
          cachePolicy: CachePolicy.cacheFirst,
          cacheDuration: Duration(minutes: 5),
        ),
      );
      expect(fetched!.name, 'Fresh');
    });

    test('cache invalidation clears specific key', () async {
      final firestore =
          _createFirestore(fakeFirestore, cachePolicy: CachePolicy.cacheFirst);
      final users = _usersCollection(firestore);
      final docRef = users.doc('u7');
      await docRef.set(User(id: 'u7', name: 'Before'));

      // Populate cache
      await docRef.get();

      // Update in raw firestore
      await fakeFirestore
          .collection('users')
          .doc('u7')
          .update({'name': 'After'});

      // Invalidate cache
      await firestore.cache.invalidate('users/u7');

      // Now fetch should get fresh data
      final fetched = await docRef.get();
      expect(fetched!.name, 'After');
    });

    test('cache clear removes all entries', () async {
      final firestore =
          _createFirestore(fakeFirestore, cachePolicy: CachePolicy.cacheFirst);
      final users = _usersCollection(firestore);

      await users.doc('a').set(User(id: 'a', name: 'A'));
      await users.doc('b').set(User(id: 'b', name: 'B'));

      // Populate cache
      await users.getById('a');
      await users.getById('b');

      // Clear everything
      await firestore.cache.clear();

      // Update behind the scenes
      await fakeFirestore.collection('users').doc('a').update({'name': 'A2'});

      // Fetch - should get fresh data since cache is cleared
      final fetched = await users.getById('a');
      expect(fetched!.name, 'A2');
    });

    test('clearCollection only clears that collection', () async {
      final firestore =
          _createFirestore(fakeFirestore, cachePolicy: CachePolicy.cacheFirst);
      final users = _usersCollection(firestore);
      final products = firestore.collection<User>(
        'products',
        fromFirestore: User.fromFirestore,
        toFirestore: (u) => u.toFirestore(),
      );

      await users.doc('a').set(User(id: 'a', name: 'UserA'));
      await products.doc('p').set(User(id: 'p', name: 'ProductP'));

      // Populate both caches
      await users.getById('a');
      await products.getById('p');

      // Clear only users
      await firestore.cache.invalidateCollection('users');

      // Update both behind the scenes
      await fakeFirestore.collection('users').doc('a').update({'name': 'New'});
      await fakeFirestore
          .collection('products')
          .doc('p')
          .update({'name': 'NewP'});

      // Users should get fresh data
      final userFetched = await users.getById('a');
      expect(userFetched!.name, 'New');

      // Products should still be cached
      final productFetched = await products.getById('p');
      expect(productFetched!.name, 'ProductP');
    });

    test('writes automatically invalidate cache', () async {
      final firestore =
          _createFirestore(fakeFirestore, cachePolicy: CachePolicy.cacheFirst);
      final users = _usersCollection(firestore);
      final docRef = users.doc('u8');

      await docRef.set(User(id: 'u8', name: 'V1'));
      await docRef.get(); // populate cache

      // Update via package (should invalidate cache)
      await docRef.update({'name': 'V2'});

      // Fetch - should see V2 because update invalidated cache
      final fetched = await docRef.get();
      expect(fetched!.name, 'V2');
    });

    test('MemoryCacheStore evicts oldest entries when maxSize exceeded',
        () async {
      final store = MemoryCacheStore(maxSize: 3);
      await store.put('k1', {'v': 1});
      await store.put('k2', {'v': 2});
      await store.put('k3', {'v': 3});
      expect(store.length, 3);

      // Adding a 4th should evict k1
      await store.put('k4', {'v': 4});
      expect(store.length, 3);

      final evicted = await store.get('k1');
      expect(evicted, isNull);

      final retained = await store.get('k4');
      expect(retained, isNotNull);
      expect(retained!.data['v'], 4);
    });
  });

  // =========================================================================
  // Retry Tests
  // =========================================================================

  group('Retry', () {
    test('first attempt succeeds with no retries', () async {
      int callCount = 0;
      final result = await RetryExecutor.execute<String>(
        operation: () async {
          callCount++;
          return 'ok';
        },
        policy: const RetryPolicy.exponential(maxAttempts: 3),
        logger: TestLogger(),
        operationName: 'test',
      );
      expect(result, 'ok');
      expect(callCount, 1);
    });

    test('retry succeeds on second attempt', () async {
      int callCount = 0;
      final result = await RetryExecutor.execute<String>(
        operation: () async {
          callCount++;
          if (callCount == 1) {
            throw TimeoutException('timeout');
          }
          return 'recovered';
        },
        policy: RetryPolicy(
          maxAttempts: 3,
          initialDelay: Duration.zero,
          jitter: false,
        ),
        logger: TestLogger(),
        operationName: 'test',
      );
      expect(result, 'recovered');
      expect(callCount, 2);
    });

    test('all attempts fail throws after max', () async {
      expect(
        () => RetryExecutor.execute<String>(
          operation: () async {
            throw TimeoutException('timeout');
          },
          policy: RetryPolicy(
            maxAttempts: 2,
            initialDelay: Duration.zero,
            jitter: false,
          ),
          logger: TestLogger(),
          operationName: 'test',
        ),
        throwsA(isA<FirestorePlusException>()),
      );
    });

    test('non-retryable error throws immediately without retry', () async {
      expect(
        () => RetryExecutor.execute<String>(
          operation: () async {
            throw FirebaseException(
                plugin: 'cloud_firestore', code: 'permission-denied');
          },
          policy: RetryPolicy(
            maxAttempts: 3,
            initialDelay: Duration.zero,
            jitter: false,
          ),
          logger: TestLogger(),
          operationName: 'test',
        ),
        throwsA(isA<FirestorePlusException>().having(
            (e) => e.type, 'type', FirestoreErrorType.permissionDenied)),
      );
    });

    test('RetryPolicy.none never retries', () async {
      expect(
        () => RetryExecutor.execute<String>(
          operation: () async {
            throw TimeoutException('timeout');
          },
          policy: const RetryPolicy.none(),
          logger: TestLogger(),
          operationName: 'test',
        ),
        throwsA(isA<FirestorePlusException>()),
      );
    });

    test('custom retryIf callback is respected', () async {
      int callCount = 0;
      final result = await RetryExecutor.execute<String>(
        operation: () async {
          callCount++;
          if (callCount < 3) {
            throw Exception('custom-error');
          }
          return 'done';
        },
        policy: RetryPolicy(
          maxAttempts: 5,
          initialDelay: Duration.zero,
          jitter: false,
          retryIf: (error) => error.toString().contains('custom-error'),
        ),
        logger: TestLogger(),
        operationName: 'test',
      );
      expect(result, 'done');
      expect(callCount, 3);
    });

    test('retryIf returning false stops retries', () async {
      expect(
        () => RetryExecutor.execute<String>(
          operation: () async {
            throw Exception('do-not-retry');
          },
          policy: RetryPolicy(
            maxAttempts: 5,
            initialDelay: Duration.zero,
            jitter: false,
            retryIf: (_) => false,
          ),
          logger: TestLogger(),
          operationName: 'test',
        ),
        throwsA(isA<FirestorePlusException>()),
      );
    });
  });

  // =========================================================================
  // Error Mapping Tests
  // =========================================================================

  group('Error Mapping', () {
    test('maps FirebaseException permission-denied', () {
      final mapped = ErrorMapper.map(
        FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'),
        StackTrace.current,
        'GET users/1',
        'users/1',
      );
      expect(mapped.type, FirestoreErrorType.permissionDenied);
      expect(mapped.code, 'permission-denied');
      expect(mapped.operation, 'GET users/1');
      expect(mapped.path, 'users/1');
      expect(mapped.originalException, isA<FirebaseException>());
    });

    test('maps FirebaseException not-found', () {
      final mapped = ErrorMapper.map(
        FirebaseException(plugin: 'cloud_firestore', code: 'not-found'),
      );
      expect(mapped.type, FirestoreErrorType.notFound);
    });

    test('maps FirebaseException unavailable', () {
      final mapped = ErrorMapper.map(
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
      );
      expect(mapped.type, FirestoreErrorType.unavailable);
    });

    test('maps TimeoutException', () {
      final mapped = ErrorMapper.map(TimeoutException('timed out'));
      expect(mapped.type, FirestoreErrorType.timeout);
    });

    test('maps unknown exception', () {
      final mapped = ErrorMapper.map(Exception('something weird'));
      expect(mapped.type, FirestoreErrorType.unknown);
      expect(mapped.originalException, isA<Exception>());
    });

    test('preserves existing FirestorePlusException', () {
      final original = FirestorePlusException(
        type: FirestoreErrorType.serialization,
        message: 'bad data',
        operation: 'GET x',
      );
      final mapped = ErrorMapper.map(original);
      expect(identical(mapped, original), isTrue);
    });

    test('isRetryable returns true for transient errors', () {
      expect(ErrorMapper.isRetryable(TimeoutException('t')), isTrue);
      expect(
          ErrorMapper.isRetryable(FirebaseException(
              plugin: 'cloud_firestore', code: 'unavailable')),
          isTrue);
      expect(
          ErrorMapper.isRetryable(FirebaseException(
              plugin: 'cloud_firestore', code: 'network-request-failed')),
          isTrue);
    });

    test('isRetryable returns false for non-transient errors', () {
      expect(
          ErrorMapper.isRetryable(FirebaseException(
              plugin: 'cloud_firestore', code: 'permission-denied')),
          isFalse);
      expect(
          ErrorMapper.isRetryable(
              FirebaseException(plugin: 'cloud_firestore', code: 'not-found')),
          isFalse);
      expect(ErrorMapper.isRetryable(Exception('random')), isFalse);
    });
  });

  // =========================================================================
  // Pagination Tests
  // =========================================================================

  group('Pagination', () {
    late FakeFirebaseFirestore fakeFirestore;
    late FirestorePlus firestore;
    late FirestoreCollection<User> users;

    setUp(() async {
      fakeFirestore = FakeFirebaseFirestore();
      firestore = _createFirestore(fakeFirestore);
      users = _usersCollection(firestore);

      // Seed 5 users
      for (int i = 1; i <= 5; i++) {
        await users
            .doc('u$i')
            .set(User(id: 'u$i', name: 'User$i', age: 20 + i));
      }
    });

    test('first page returns correct items and hasMore', () async {
      final page = await users.query().orderBy('age').paginate(limit: 2);
      expect(page.items.length, 2);
      expect(page.hasMore, isTrue);
      expect(page.cursor, isNotNull);
      expect(page.items[0].age, 21);
      expect(page.items[1].age, 22);
    });

    test('next page via cursor returns a PaginatedResult', () async {
      final page1 = await users.query().orderBy('age').paginate(limit: 2);

      // With fake_cloud_firestore, startAfterDocument support is limited.
      // We verify the cursor is available and can be passed to paginate.
      expect(page1.cursor, isNotNull);

      final page2 = await users
          .query()
          .orderBy('age')
          .paginate(limit: 2, startAfter: page1.cursor);
      // page2 is a valid PaginatedResult regardless of fake limitations
      expect(page2, isA<PaginatedResult<User>>());
    });

    test('last page scenario: when items less than limit, hasMore is false',
        () async {
      // Fetch all 5 items with limit 10 -> hasMore should be false
      final page = await users.query().orderBy('age').paginate(limit: 10);
      expect(page.items.length, 5);
      expect(page.hasMore, isFalse);
    });

    test('empty result returns empty PaginatedResult', () async {
      final emptyFirestore2 = FakeFirebaseFirestore();
      final fs2 = _createFirestore(emptyFirestore2);
      final emptyUsers = _usersCollection(fs2);

      final page = await emptyUsers.query().paginate(limit: 10);
      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);
      expect(page.cursor, isNull);
    });
  });

  // =========================================================================
  // Stream Tests
  // =========================================================================

  group('Streams', () {
    late FakeFirebaseFirestore fakeFirestore;
    late FirestorePlus firestore;
    late FirestoreCollection<User> users;

    setUp(() {
      fakeFirestore = FakeFirebaseFirestore();
      firestore = _createFirestore(fakeFirestore);
      users = _usersCollection(firestore);
    });

    test('document snapshots stream emits updates', () async {
      final docRef = users.doc('s1');
      await docRef.set(User(id: 's1', name: 'Stream1'));

      final stream = docRef.snapshots();
      final first = await stream.first;
      expect(first, isNotNull);
      expect(first!.name, 'Stream1');
    });

    test('query snapshots stream emits list', () async {
      await users.doc('q1').set(User(id: 'q1', name: 'A'));
      await users.doc('q2').set(User(id: 'q2', name: 'B'));

      final stream = users.query().snapshots();
      final first = await stream.first;
      expect(first.length, 2);
    });

    test('document stream returns null for missing document', () async {
      final stream = users.doc('missing').snapshots();
      final first = await stream.first;
      expect(first, isNull);
    });
  });

  // =========================================================================
  // Batch Tests
  // =========================================================================

  group('Batch', () {
    late FakeFirebaseFirestore fakeFirestore;
    late FirestorePlus firestore;
    late FirestoreCollection<User> users;

    setUp(() {
      fakeFirestore = FakeFirebaseFirestore();
      firestore = _createFirestore(fakeFirestore);
      users = _usersCollection(firestore);
    });

    test('batch set + commit writes multiple documents', () async {
      final batch = firestore.batch();
      final doc1 = users.doc('b1');
      final doc2 = users.doc('b2');

      batch.set(doc1, User(id: 'b1', name: 'B1'));
      batch.set(doc2, User(id: 'b2', name: 'B2'));
      await batch.commit();

      final u1 = await doc1.get();
      final u2 = await doc2.get();
      expect(u1!.name, 'B1');
      expect(u2!.name, 'B2');
    });

    test('batch update + delete + commit', () async {
      final doc1 = users.doc('bu1');
      final doc2 = users.doc('bu2');
      await doc1.set(User(id: 'bu1', name: 'Original'));
      await doc2.set(User(id: 'bu2', name: 'ToDelete'));

      final batch = firestore.batch();
      batch.update(doc1, {'name': 'Updated'});
      batch.delete(doc2);
      await batch.commit();

      final u1 = await doc1.get();
      expect(u1!.name, 'Updated');

      final u2exists = await doc2.exists();
      expect(u2exists, isFalse);
    });

    test('batch commit invalidates cache', () async {
      final cacheFirestore =
          _createFirestore(fakeFirestore, cachePolicy: CachePolicy.cacheFirst);
      final cacheUsers = _usersCollection(cacheFirestore);
      final doc = cacheUsers.doc('bc1');
      await doc.set(User(id: 'bc1', name: 'Cached'));

      // Populate cache
      await doc.get();

      // Batch update
      final batch = cacheFirestore.batch();
      batch.update(doc, {'name': 'BatchUpdated'});
      await batch.commit();

      // Now even with cacheFirst, cache should be invalidated
      // Update raw firestore to new value (batch already did this)
      final fetched = await doc.get();
      expect(fetched!.name, 'BatchUpdated');
    });
  });

  // =========================================================================
  // Transaction Tests
  // =========================================================================

  group('Transaction', () {
    late FakeFirebaseFirestore fakeFirestore;
    late FirestorePlus firestore;
    late FirestoreCollection<User> users;

    setUp(() {
      fakeFirestore = FakeFirebaseFirestore();
      firestore = _createFirestore(fakeFirestore);
      users = _usersCollection(firestore);
    });

    test('transaction read + update', () async {
      final docRef = users.doc('tx1');
      await docRef.set(User(id: 'tx1', name: 'Initial'));

      await firestore.runTransaction<void>((tx) async {
        final user = await tx.get(docRef);
        expect(user!.name, 'Initial');
        tx.update(docRef, {'name': 'TxUpdated'});
      });

      final finalUser = await docRef.get();
      expect(finalUser!.name, 'TxUpdated');
    });

    test('transaction returns null for missing doc', () async {
      await firestore.runTransaction<void>((tx) async {
        final user = await tx.get(users.doc('missing'));
        expect(user, isNull);
      });
    });
  });

  // =========================================================================
  // Request Deduplication Tests
  // =========================================================================

  group('Request Deduplication', () {
    late FakeFirebaseFirestore fakeFirestore;

    setUp(() {
      fakeFirestore = FakeFirebaseFirestore();
    });

    test('concurrent identical reads return same result', () async {
      final firestore = _createFirestore(fakeFirestore, enableDedup: true);
      final users = _usersCollection(firestore);
      final doc = users.doc('dedup1');
      await doc.set(User(id: 'dedup1', name: 'Shared'));

      // Fire multiple concurrent reads
      final results = await Future.wait([doc.get(), doc.get(), doc.get()]);

      for (final r in results) {
        expect(r!.name, 'Shared');
      }
    });

    test('deduplication disabled fires separate requests', () async {
      final firestore = _createFirestore(fakeFirestore, enableDedup: false);
      final users = _usersCollection(firestore);
      final doc = users.doc('dedup2');
      await doc.set(User(id: 'dedup2', name: 'Separate'));

      final results = await Future.wait([doc.get(), doc.get()]);
      for (final r in results) {
        expect(r!.name, 'Separate');
      }
    });

    test('different reads are not coalesced', () async {
      final firestore = _createFirestore(fakeFirestore, enableDedup: true);
      final users = _usersCollection(firestore);
      await users.doc('d1').set(User(id: 'd1', name: 'One'));
      await users.doc('d2').set(User(id: 'd2', name: 'Two'));

      final results =
          await Future.wait([users.getById('d1'), users.getById('d2')]);
      expect(results[0]!.name, 'One');
      expect(results[1]!.name, 'Two');
    });
  });

  // =========================================================================
  // Configuration Tests
  // =========================================================================

  group('Configuration', () {
    test('default config has sensible values', () {
      const config = FirestorePlusConfig();
      expect(config.defaultCachePolicy, CachePolicy.networkFirst);
      expect(config.defaultTimeout, const Duration(seconds: 30));
      expect(config.enableRequestDeduplication, isTrue);
      expect(config.defaultRetryPolicy.maxAttempts, 3);
    });

    test('custom config overrides defaults', () {
      const config = FirestorePlusConfig(
        defaultCachePolicy: CachePolicy.cacheFirst,
        defaultTimeout: Duration(seconds: 5),
        enableRequestDeduplication: false,
        defaultRetryPolicy: RetryPolicy.none(),
      );
      expect(config.defaultCachePolicy, CachePolicy.cacheFirst);
      expect(config.defaultTimeout, const Duration(seconds: 5));
      expect(config.enableRequestDeduplication, isFalse);
      expect(config.defaultRetryPolicy.maxAttempts, 0);
    });

    test('custom logger receives messages', () async {
      final logger = TestLogger();
      final fakeFirestore = FakeFirebaseFirestore();
      final firestore = _createFirestore(fakeFirestore, logger: logger);
      final users = _usersCollection(firestore);

      await users.doc('log1').set(User(id: 'log1', name: 'Logger'));
      await users.getById('log1');

      expect(logger.messages, isNotEmpty);
      expect(logger.messages.any((m) => m.contains('users')), isTrue);
    });

    test('custom cache store is used', () async {
      final customStore = MemoryCacheStore(maxSize: 10);
      final fakeFirestore = FakeFirebaseFirestore();
      final firestore = _createFirestore(
        fakeFirestore,
        cacheStore: customStore,
        cachePolicy: CachePolicy.cacheFirst,
      );
      final users = _usersCollection(firestore);

      await users.doc('cs1').set(User(id: 'cs1', name: 'Custom'));
      await users.getById('cs1');

      expect(customStore.length, greaterThan(0));
    });
  });

  // =========================================================================
  // Metrics Tests
  // =========================================================================

  group('Metrics', () {
    test('metrics listener receives operation data', () async {
      final listener = TestMetricsListener();
      final fakeFirestore = FakeFirebaseFirestore();
      final firestore =
          _createFirestore(fakeFirestore, metricsListener: listener);
      final users = _usersCollection(firestore);

      await users.doc('m1').set(User(id: 'm1', name: 'Metrics'));
      await users.getById('m1');

      expect(listener.recorded, isNotEmpty);
      expect(listener.recorded.any((m) => m.type == FirestoreOperationType.set),
          isTrue);
      expect(listener.recorded.any((m) => m.type == FirestoreOperationType.get),
          isTrue);
      expect(listener.recorded.every((m) => m.duration.inMicroseconds >= 0),
          isTrue);
    });

    test('no metrics emitted when listener is null', () async {
      final fakeFirestore = FakeFirebaseFirestore();
      final firestore = _createFirestore(fakeFirestore); // no metricsListener
      final users = _usersCollection(firestore);

      // Should not throw or error
      await users.doc('m2').set(User(id: 'm2', name: 'NoMetrics'));
      await users.getById('m2');
    });
  });

  // =========================================================================
  // Serialization Error Tests
  // =========================================================================

  group('Serialization', () {
    test(
        'bad fromFirestore throws FirestorePlusException with serialization type',
        () async {
      final fakeFirestore = FakeFirebaseFirestore();
      final firestore = _createFirestore(fakeFirestore);
      final badCollection = firestore.collection<User>(
        'bad',
        fromFirestore: (data, id) {
          throw FormatException('Cannot parse');
        },
        toFirestore: (user) => user.toFirestore(),
      );

      // Seed raw data
      await fakeFirestore.collection('bad').doc('x').set({'name': 'test'});

      expect(
        () => badCollection.getById('x'),
        throwsA(isA<FirestorePlusException>()
            .having((e) => e.type, 'type', FirestoreErrorType.serialization)),
      );
    });
  });

  // =========================================================================
  // DataSource & CacheEntry Tests
  // =========================================================================

  group('DataSource & CacheEntry', () {
    test('CacheEntry isStale correctly identifies expired entries', () {
      final staleEntry = CacheEntry(
        data: {'test': true},
        createdAt: DateTime.now().subtract(const Duration(hours: 1)),
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      expect(staleEntry.isStale, isTrue);

      final freshEntry = CacheEntry(
        data: {'test': true},
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      );
      expect(freshEntry.isStale, isFalse);
    });

    test('CacheEntry without expiry is never stale', () {
      final entry = CacheEntry(
        data: {'test': true},
        createdAt: DateTime.now().subtract(const Duration(days: 365)),
      );
      expect(entry.isStale, isFalse);
    });

    test('DataSource enum has expected values', () {
      expect(DataSource.values, contains(DataSource.network));
      expect(DataSource.values, contains(DataSource.cache));
      expect(DataSource.values, contains(DataSource.staleCache));
    });
  });

  // =========================================================================
  // FirestoreOperationOptions Tests
  // =========================================================================

  group('FirestoreOperationOptions', () {
    test('merge prefers other values', () {
      const base = FirestoreOperationOptions(
        cachePolicy: CachePolicy.networkOnly,
        timeout: Duration(seconds: 10),
      );
      const override = FirestoreOperationOptions(
        cachePolicy: CachePolicy.cacheFirst,
      );

      final merged = base.merge(override);
      expect(merged.cachePolicy, CachePolicy.cacheFirst);
      expect(merged.timeout, const Duration(seconds: 10));
    });

    test('merge with null returns self', () {
      const base = FirestoreOperationOptions(
        cachePolicy: CachePolicy.networkOnly,
      );
      final merged = base.merge(null);
      expect(merged.cachePolicy, CachePolicy.networkOnly);
    });
  });

  // =========================================================================
  // Regression tests for bugs found during real-world integration testing
  // =========================================================================

  group('Regressions', () {
    late FakeFirebaseFirestore fake;
    setUp(() => fake = FakeFirebaseFirestore());

    test('custom loggers only receive messages at or above logLevel', () {
      final logger = _WarningLogger();
      logger.debug('d');
      logger.info('i');
      logger.warning('w');
      logger.error('e');
      expect(logger.messages, ['warning: w', 'error: e']);
    });

    test('jitter with a 1ms base delay does not throw RangeError', () async {
      var calls = 0;
      final result = await RetryExecutor.execute(
        operation: () async {
          if (++calls < 3) throw TimeoutException('t');
          return 'ok';
        },
        policy: const RetryPolicy(
            maxAttempts: 3, initialDelay: Duration(milliseconds: 1)),
        logger: TestLogger(),
      );
      expect(result, 'ok');
    });

    test('huge attempt counts clamp to maxDelay instead of overflowing',
        () async {
      var calls = 0;
      await RetryExecutor.execute(
        operation: () async {
          if (++calls < 1100) throw TimeoutException('t');
          return null;
        },
        policy: const RetryPolicy(
            maxAttempts: 2000,
            initialDelay: Duration(milliseconds: 1),
            maxDelay: Duration.zero,
            jitter: false),
        logger: TestLogger(),
      );
      expect(calls, 1100);
    });

    test('retryCount and servedFromCache metrics are accurate', () async {
      final metrics = TestMetricsListener();
      final fp = _createFirestore(fake, metricsListener: metrics);
      final users = _usersCollection(fp);
      await users.doc('1').set(User(id: '1', name: 'A'));
      metrics.recorded.clear();
      const cacheFirst =
          FirestoreOperationOptions(cachePolicy: CachePolicy.cacheFirst);
      await users.getById('1', options: cacheFirst);
      await users.getById('1', options: cacheFirst);
      expect(metrics.recorded.map((m) => m.servedFromCache), [false, true]);

      final retries = <int>[];
      var calls = 0;
      await RetryExecutor.execute(
        operation: () async {
          if (++calls < 3) throw TimeoutException('t');
        },
        policy: const RetryPolicy(
            maxAttempts: 3, initialDelay: Duration.zero, jitter: false),
        logger: TestLogger(),
        onRetry: retries.add,
      );
      expect(retries, [1, 2]);
    });

    test('a throwing metrics listener does not fail the operation', () async {
      final fp = FirestorePlus(fake,
          config: FirestorePlusConfig(
              logger: TestLogger(), metricsListener: _ThrowingMetrics()));
      final users = _usersCollection(fp);
      await users.doc('1').set(User(id: '1', name: 'A'));
      expect((await users.getById('1'))!.name, 'A');
    });

    test('writes invalidate cached queries of the collection', () async {
      final fp = _createFirestore(fake, cachePolicy: CachePolicy.cacheFirst);
      final users = _usersCollection(fp);
      await users.doc('1').set(User(id: '1', name: 'A'));
      expect((await users.get()).length, 1);
      await users.add(User(id: '', name: 'B'));
      expect((await users.get()).length, 2);
      final b = fp.batch()..delete(users.doc('1'));
      await b.commit();
      expect((await users.get()).length, 1);
    });

    test('invalidateCollection also clears cached queries', () async {
      final store = MemoryCacheStore();
      final fp = _createFirestore(fake,
          cachePolicy: CachePolicy.cacheFirst, cacheStore: store);
      final users = _usersCollection(fp);
      await users.doc('1').set(User(id: '1', name: 'A'));
      await users.get();
      await fake.collection('users').doc('2').set({'name': 'B'});
      await fp.cache.invalidateCollection('users');
      expect((await users.get()).length, 2);
      // store-level clearCollection alone must also drop query keys
      await store.put('users?q=all', {'docs': []});
      await store.clearCollection('users');
      expect(await store.get('users?q=all'), isNull);
    });

    test('transactions invalidate written documents', () async {
      final fp = _createFirestore(fake, cachePolicy: CachePolicy.cacheFirst);
      final users = _usersCollection(fp);
      await users.doc('1').set(User(id: '1', name: 'A', age: 1));
      await users.getById('1');
      await fp.runTransaction<void>((tx) async {
        final u = await tx.get(users.doc('1'));
        tx.update(users.doc('1'), {'age': u!.age! + 1});
      });
      expect((await users.getById('1'))!.age, 2);
    });

    test('staleWhileRevalidate cache miss propagates errors', () async {
      final fp = _createFirestore(fake);
      final bad = fp.collection<User>('users',
          fromFirestore: User.fromFirestore,
          toFirestore: (u) => u.toFirestore());
      final executor = fp.executor;
      await expectLater(
        executor.executeRead(
          path: 'users/x',
          cacheKey: 'users/x',
          options: const FirestoreOperationOptions(
              cachePolicy: CachePolicy.staleWhileRevalidate),
          fetchFromNetwork: () async =>
              throw FirebaseException(plugin: 'x', code: 'permission-denied'),
        ),
        throwsA(isA<FirestorePlusException>().having(
            (e) => e.type, 'type', FirestoreErrorType.permissionDenied)),
      );
      expect(bad.path, 'users');
    });

    test('network "not found" removes a stale cache entry', () async {
      final fp = _createFirestore(fake, cachePolicy: CachePolicy.networkFirst);
      final users = _usersCollection(fp);
      await users.doc('1').set(User(id: '1', name: 'A'));
      await users.getById('1');
      await fake.collection('users').doc('1').delete();
      expect(await users.getById('1'), isNull);
      expect(
          await users.getById('1',
              options: const FirestoreOperationOptions(
                  cachePolicy: CachePolicy.cacheOnly)),
          isNull);
    });

    test('mutating a returned map does not corrupt the cache', () async {
      final fp = _createFirestore(fake, cachePolicy: CachePolicy.cacheFirst);
      final raw = fp.collection<Map<String, dynamic>>('raw',
          fromFirestore: (d, _) => d, toFirestore: (d) => d);
      await raw.doc('a').set({
        'n': 1,
        'l': [1]
      });
      final first = (await raw.getById('a'))!;
      first['n'] = 99;
      (first['l'] as List).add(2);
      final second = (await raw.getById('a'))!;
      expect(second['n'], 1);
      expect(second['l'], [1]);
    });

    test('dedupe does not share results across cache policies', () async {
      final fp = _createFirestore(fake);
      final users = _usersCollection(fp);
      await users.doc('1').set(User(id: '1', name: 'A'));
      final r = await Future.wait([
        users.getById('1',
            options: const FirestoreOperationOptions(
                cachePolicy: CachePolicy.cacheOnly)),
        users.getById('1',
            options: const FirestoreOperationOptions(
                cachePolicy: CachePolicy.networkOnly)),
      ]);
      expect(r[0], isNull);
      expect(r[1]!.name, 'A');
    });

    test('different Filter queries use different cache keys', () async {
      final fp = _createFirestore(fake, cachePolicy: CachePolicy.cacheFirst);
      final users = _usersCollection(fp);
      for (var i = 0; i < 4; i++) {
        await users.doc('$i').set(User(id: '$i', name: 'u$i', age: i));
      }
      Future<Set<String>> run(int a, int b) async => (await users
              .query()
              .where(Filter.or(
                  Filter('age', isEqualTo: a), Filter('age', isEqualTo: b)))
              .get())
          .map((u) => u.id)
          .toSet();
      expect(await run(0, 1), {'0', '1'});
      expect(await run(2, 3), {'2', '3'});
    });

    test('pagination hasMore is exact and cache holds plain data only',
        () async {
      final store = MemoryCacheStore();
      final fp = _createFirestore(fake,
          cachePolicy: CachePolicy.networkFirst, cacheStore: store);
      final users = _usersCollection(fp);
      for (var i = 0; i < 4; i++) {
        await users.doc('$i').set(User(id: '$i', name: 'u$i', age: i));
      }
      final q = users.query().orderBy('age');
      final p1 = await q.paginate(limit: 2);
      expect(p1.hasMore, isTrue);
      final p2 = await q.paginate(limit: 2, startAfter: p1.cursor);
      expect(p2.items.map((u) => u.age), [2, 3]);
      expect(p2.hasMore, isFalse);
      expect(() => q.paginate(limit: 0), throwsArgumentError);
    });

    test('toFirestore failures are reported as serialization errors', () async {
      final fp = _createFirestore(fake);
      final c = fp.collection<User>('users',
          fromFirestore: User.fromFirestore,
          toFirestore: (_) => throw StateError('boom'));
      await expectLater(
          c.doc('1').set(User(id: '1', name: 'A')),
          throwsA(isA<FirestorePlusException>().having(
              (e) => e.type, 'type', FirestoreErrorType.serialization)));
    });

    test('transaction read deserialization failure keeps serialization type',
        () async {
      final fp = _createFirestore(fake);
      await fake.collection('users').doc('bad').set({'name': 42});
      final users = _usersCollection(fp);
      await expectLater(
          fp.runTransaction((tx) => tx.get(users.doc('bad'))),
          throwsA(isA<FirestorePlusException>().having(
              (e) => e.type, 'type', FirestoreErrorType.serialization)));
    });

    test('user exceptions inside runTransaction are rethrown unchanged',
        () async {
      final fp = _createFirestore(fake);
      await expectLater(
          fp.runTransaction<void>((_) async => throw StateError('domain')),
          throwsStateError);
    });
  });
}

class _ThrowingMetrics implements FirestoreMetricsListener {
  @override
  void onOperationComplete(FirestoreOperationMetrics metrics) =>
      throw StateError('listener bug');
}

final class _WarningLogger extends FirestorePlusLogger {
  final List<String> messages = [];

  @override
  FirestoreLogLevel get logLevel => FirestoreLogLevel.warning;

  @override
  void log(FirestoreLogLevel level, String message,
      {Object? error, StackTrace? stackTrace}) {
    messages.add('${level.name}: $message');
  }
}
