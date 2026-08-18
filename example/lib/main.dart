// ignore_for_file: avoid_print

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firestore_plus/firestore_plus.dart';
import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// 1. TYPED MODELS
// ---------------------------------------------------------------------------

/// A sample User model demonstrating typed serialization.
class User {
  final String id;
  final String name;
  final String email;
  final int age;

  User(
      {required this.id,
      required this.name,
      required this.email,
      this.age = 0});

  /// Deserialize from Firestore document data.
  factory User.fromFirestore(Map<String, dynamic> data, String id) {
    return User(
      id: id,
      name: data['name'] as String? ?? '',
      email: data['email'] as String? ?? '',
      age: data['age'] as int? ?? 0,
    );
  }

  /// Serialize to Firestore document data.
  Map<String, dynamic> toFirestore() => {
        'name': name,
        'email': email,
        'age': age,
      };

  @override
  String toString() => 'User(id: $id, name: $name, email: $email, age: $age)';
}

// ---------------------------------------------------------------------------
// 2. CUSTOM LOGGER
// ---------------------------------------------------------------------------

/// Example custom logger that prefixes all messages with a timestamp.
final class TimestampLogger extends FirestorePlusLogger {
  @override
  FirestoreLogLevel get logLevel => FirestoreLogLevel.debug;

  @override
  void log(FirestoreLogLevel level, String message,
      {Object? error, StackTrace? stackTrace}) {
    final timestamp = DateTime.now().toIso8601String();
    print('[$timestamp] [${level.name.toUpperCase()}] $message');
    if (error != null) {
      print('[$timestamp] ERROR: $error');
    }
  }
}

// ---------------------------------------------------------------------------
// 3. CUSTOM METRICS LISTENER
// ---------------------------------------------------------------------------

/// Example metrics listener that prints operation stats.
class AppMetricsListener implements FirestoreMetricsListener {
  int totalOps = 0;
  int cacheHits = 0;
  int failures = 0;

  @override
  void onOperationComplete(FirestoreOperationMetrics metrics) {
    totalOps++;
    if (metrics.servedFromCache) cacheHits++;
    if (!metrics.isSuccess) failures++;
    print(
      '📊 Metric: ${metrics.type.name.toUpperCase()} ${metrics.path} '
      '(${metrics.duration.inMilliseconds}ms, '
      'cache: ${metrics.servedFromCache}, '
      'retries: ${metrics.retryCount})',
    );
  }

  void printSummary() {
    print('═══ Metrics Summary ═══');
    print('Total operations: $totalOps');
    print('Cache hits: $cacheHits');
    print('Failures: $failures');
    print('═══════════════════════');
  }
}

// ---------------------------------------------------------------------------
// MAIN APP
// ---------------------------------------------------------------------------

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // In a real app, initialize Firebase first:
  // await Firebase.initializeApp();
  runApp(const FirestorePlusExampleApp());
}

class FirestorePlusExampleApp extends StatelessWidget {
  const FirestorePlusExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Firestore Plus Example',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const ExampleHomePage(),
    );
  }
}

class ExampleHomePage extends StatelessWidget {
  const ExampleHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Firestore Plus Example')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'This example demonstrates the firestore_plus package API.\n'
            'See the source code and console output for usage patterns.',
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => _runExample(context),
            child: const Text('Run Example (see console)'),
          ),
        ],
      ),
    );
  }

  void _runExample(BuildContext context) {
    // In a real app with Firebase initialized, call _demonstrateFeatures().
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Initialize Firebase first, then uncomment _demonstrateFeatures().',
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// FEATURE DEMONSTRATIONS
// ---------------------------------------------------------------------------

/// Demonstrates all major features of firestore_plus.
///
/// Call this after Firebase initialization:
/// ```dart
/// await Firebase.initializeApp();
/// await demonstrateFeatures();
/// ```
Future<void> demonstrateFeatures() async {
  final metricsListener = AppMetricsListener();

  // ── 1. Initialization ──────────────────────────────────────────────────
  print('\n═══ 1. INITIALIZATION ═══');

  final firestorePlus = FirestorePlus(
    FirebaseFirestore.instance,
    config: FirestorePlusConfig(
      // Cache: prefer network, fall back to cache on failure
      defaultCachePolicy: CachePolicy.networkFirst,
      // Retry transient failures up to 3 times
      defaultRetryPolicy: const RetryPolicy.exponential(maxAttempts: 3),
      // Global timeout for all operations
      defaultTimeout: const Duration(seconds: 15),
      // Enable request deduplication
      enableRequestDeduplication: true,
      // Custom logger
      logger: TimestampLogger(),
      // Metrics listener
      metricsListener: metricsListener,
      // Custom cache store (or use default MemoryCacheStore)
      cacheStore: MemoryCacheStore(maxSize: 200),
    ),
  );

  // ── 2. Typed Collection ────────────────────────────────────────────────
  print('\n═══ 2. TYPED COLLECTION ═══');

  final users = firestorePlus.collection<User>(
    'users',
    fromFirestore: User.fromFirestore,
    toFirestore: (user) => user.toFirestore(),
  );

  // ── 3. CRUD Operations ────────────────────────────────────────────────
  print('\n═══ 3. CRUD ═══');

  // Add
  final newDoc = await users.add(
    User(id: '', name: 'Alice', email: 'alice@example.com', age: 30),
  );
  print('Added user: ${newDoc.id}');

  // Set (with specific ID)
  await users.doc('user-bob').set(
        User(id: 'user-bob', name: 'Bob', email: 'bob@example.com', age: 25),
      );
  print('Set user: user-bob');

  // Get
  final alice = await users.getById(newDoc.id);
  print('Got user: $alice');

  // Update
  await users.doc(newDoc.id).update({'name': 'Alice Updated', 'age': 31});
  print('Updated user');

  // Exists
  final exists = await users.exists(newDoc.id);
  print('User exists: $exists');

  // Delete
  await users.delete(newDoc.id);
  print('Deleted user');

  // ── 4. Queries ─────────────────────────────────────────────────────────
  print('\n═══ 4. QUERIES ═══');

  // Seed some users for queries
  for (int i = 1; i <= 10; i++) {
    await users.doc('q$i').set(User(
          id: 'q$i',
          name: 'User $i',
          email: 'user$i@example.com',
          age: 20 + i,
        ));
  }

  final youngUsers = await users
      .query()
      .where('age', isLessThan: 26)
      .orderBy('age')
      .limit(5)
      .get();
  print('Young users: ${youngUsers.map((u) => u.name).toList()}');

  // Count
  final count = await users.query().count();
  print('Total users: $count');

  // ── 5. Cache Policies ──────────────────────────────────────────────────
  print('\n═══ 5. CACHE POLICIES ═══');

  // Cache first — returns cached data if available
  final cachedUser = await users.getById(
    'user-bob',
    options: const FirestoreOperationOptions(
      cachePolicy: CachePolicy.cacheFirst,
      cacheDuration: Duration(minutes: 5),
    ),
  );
  print('cacheFirst: $cachedUser');

  // Network only — always fetches fresh data
  final freshUser = await users.getById(
    'user-bob',
    options: const FirestoreOperationOptions(
      cachePolicy: CachePolicy.networkOnly,
    ),
  );
  print('networkOnly: $freshUser');

  // Stale while revalidate — returns cached, refreshes in background
  final staleUser = await users.getById(
    'user-bob',
    options: const FirestoreOperationOptions(
      cachePolicy: CachePolicy.staleWhileRevalidate,
    ),
  );
  print('staleWhileRevalidate: $staleUser');

  // ── 6. Cache Invalidation ──────────────────────────────────────────────
  print('\n═══ 6. CACHE INVALIDATION ═══');

  await firestorePlus.cache.invalidate('users/user-bob');
  print('Invalidated users/user-bob');

  await firestorePlus.cache.invalidateCollection('users');
  print('Invalidated all users');

  await firestorePlus.cache.clear();
  print('Cleared entire cache');

  // ── 7. Retry with Custom Policy ────────────────────────────────────────
  print('\n═══ 7. RETRY ═══');

  final retryUser = await users.getById(
    'user-bob',
    options: FirestoreOperationOptions(
      retryPolicy: RetryPolicy(
        maxAttempts: 5,
        initialDelay: const Duration(milliseconds: 200),
        maxDelay: const Duration(seconds: 5),
        backoffMultiplier: 2.0,
        jitter: true,
        retryIf: (error) {
          // Custom logic: only retry timeout errors
          if (error is FirestorePlusException) {
            return error.type == FirestoreErrorType.timeout;
          }
          return false;
        },
      ),
    ),
  );
  print('Retry result: $retryUser');

  // ── 8. Error Handling ──────────────────────────────────────────────────
  print('\n═══ 8. ERROR HANDLING ═══');

  try {
    await users.getById('nonexistent-user');
  } on FirestorePlusException catch (e) {
    print('Caught: ${e.type} — ${e.message}');
    print('Operation: ${e.operation}');
    print('Path: ${e.path}');
    print('Original: ${e.originalException}');
  }

  // ── 9. Pagination ──────────────────────────────────────────────────────
  print('\n═══ 9. PAGINATION ═══');

  final page1 = await users.query().orderBy('age').paginate(limit: 3);
  print('Page 1: ${page1.items.length} items, hasMore: ${page1.hasMore}');

  if (page1.hasMore && page1.cursor != null) {
    final page2 = await users
        .query()
        .orderBy('age')
        .paginate(limit: 3, startAfter: page1.cursor);
    print('Page 2: ${page2.items.length} items, hasMore: ${page2.hasMore}');
  }

  // ── 10. Streams ────────────────────────────────────────────────────────
  print('\n═══ 10. STREAMS ═══');

  // Document stream
  final docStream = users.doc('user-bob').snapshots();
  print('Document stream created (listen to receive updates)');

  // Query stream
  final queryStream = users.query().where('age', isGreaterThan: 25).snapshots();
  print('Query stream created');

  // Listen briefly then cancel
  final subscription = docStream.listen((user) {
    print('Stream update: $user');
  });
  await Future.delayed(const Duration(seconds: 1));
  await subscription.cancel();
  print('Stream subscription cancelled');

  // Consume queryStream briefly to avoid lint
  final querySubscription = queryStream.listen((_) {});
  await querySubscription.cancel();

  // ── 11. Batch Operations ───────────────────────────────────────────────
  print('\n═══ 11. BATCH OPERATIONS ═══');

  final batch = firestorePlus.batch();
  batch.set(
    users.doc('batch1'),
    User(id: 'batch1', name: 'Batch User 1', email: 'b1@example.com'),
  );
  batch.set(
    users.doc('batch2'),
    User(id: 'batch2', name: 'Batch User 2', email: 'b2@example.com'),
  );
  batch.update(users.doc('user-bob'), {'name': 'Bob (Batch Updated)'});
  await batch.commit();
  print('Batch committed');

  // ── 12. Transactions ───────────────────────────────────────────────────
  print('\n═══ 12. TRANSACTIONS ═══');

  await firestorePlus.runTransaction<void>((tx) async {
    final doc = users.doc('user-bob');
    final user = await tx.get(doc);
    if (user != null) {
      tx.update(doc, {'age': user.age + 1});
      print('Transaction: incremented Bob age to ${user.age + 1}');
    }
  });

  // ── 13. Timeouts ───────────────────────────────────────────────────────
  print('\n═══ 13. TIMEOUTS ═══');

  try {
    await users.getById(
      'user-bob',
      options: const FirestoreOperationOptions(
        timeout: Duration(seconds: 5),
      ),
    );
    print('Fetched within timeout');
  } on FirestorePlusException catch (e) {
    if (e.type == FirestoreErrorType.timeout) {
      print('Operation timed out!');
    }
  }

  // ── 14. Metrics Summary ────────────────────────────────────────────────
  print('\n═══ 14. METRICS ═══');
  metricsListener.printSummary();

  // ── Cleanup ────────────────────────────────────────────────────────────
  print('\n═══ CLEANUP ═══');
  for (int i = 1; i <= 10; i++) {
    await users.delete('q$i');
  }
  await users.delete('user-bob');
  await users.delete('batch1');
  await users.delete('batch2');
  print('Cleanup complete');
}
