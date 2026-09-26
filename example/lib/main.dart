import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firestore_plus/firestore_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// FIREBASE SETUP
//
// By default this example talks to the local Firestore emulator using a demo
// project, so it runs without any Firebase project:
//
//   firebase emulators:start --only firestore --project demo-firestore-plus
//   flutter run
//
// To use your own project, run `flutterfire configure`, pass
// `DefaultFirebaseOptions.currentPlatform` to `Firebase.initializeApp` and set
// `useEmulator` to false.
// ---------------------------------------------------------------------------

const useEmulator = true;

FirebaseOptions get _demoOptions {
  final platform = kIsWeb
      ? 'web'
      : defaultTargetPlatform == TargetPlatform.android
          ? 'android'
          : 'ios';
  return FirebaseOptions(
    apiKey: 'demo-api-key',
    appId: '1:1234567890:$platform:0123456789abcdef',
    messagingSenderId: '1234567890',
    projectId: 'demo-firestore-plus',
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: _demoOptions);
  if (useEmulator) {
    final host = !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? '10.0.2.2' // Android emulator -> host machine
        : 'localhost';
    FirebaseFirestore.instance.useFirestoreEmulator(host, 8080);
  }
  runApp(const FirestorePlusExampleApp());
}

// ---------------------------------------------------------------------------
// 1. TYPED MODEL
// ---------------------------------------------------------------------------

class User {
  final String id;
  final String name;
  final String email;
  final int age;

  const User({
    this.id = '',
    required this.name,
    required this.email,
    this.age = 0,
  });

  factory User.fromFirestore(Map<String, dynamic> data, String id) {
    return User(
      id: id,
      name: data['name'] as String? ?? '',
      email: data['email'] as String? ?? '',
      age: data['age'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toFirestore() => {
        'name': name,
        'email': email,
        'age': age,
      };

  @override
  String toString() => 'User($id, $name, age $age)';
}

// ---------------------------------------------------------------------------
// 2. CUSTOM LOGGER & METRICS
// ---------------------------------------------------------------------------

/// Forwards warnings and errors to the on-screen log.
final class UiLogger extends FirestorePlusLogger {
  final void Function(String line) sink;
  const UiLogger(this.sink);

  @override
  FirestoreLogLevel get logLevel => FirestoreLogLevel.warning;

  @override
  void log(FirestoreLogLevel level, String message,
      {Object? error, StackTrace? stackTrace}) {
    sink('[${level.name}] $message${error != null ? ' ($error)' : ''}');
  }
}

class AppMetricsListener implements FirestoreMetricsListener {
  int totalOps = 0;
  int cacheHits = 0;
  int failures = 0;
  int retries = 0;

  @override
  void onOperationComplete(FirestoreOperationMetrics metrics) {
    totalOps++;
    if (metrics.servedFromCache) cacheHits++;
    if (!metrics.isSuccess) failures++;
    retries += metrics.retryCount;
  }

  @override
  String toString() => 'ops: $totalOps, cache hits: $cacheHits, '
      'failures: $failures, retries: $retries';
}

// ---------------------------------------------------------------------------
// APP
// ---------------------------------------------------------------------------

class FirestorePlusExampleApp extends StatelessWidget {
  const FirestorePlusExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'firestore_plus example',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const ExampleHomePage(),
    );
  }
}

class ExampleHomePage extends StatefulWidget {
  const ExampleHomePage({super.key});

  @override
  State<ExampleHomePage> createState() => _ExampleHomePageState();
}

class _ExampleHomePageState extends State<ExampleHomePage> {
  final _log = <String>[];
  final _metrics = AppMetricsListener();
  late final FirestorePlus _firestorePlus;
  late final FirestoreCollection<User> _users;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _firestorePlus = FirestorePlus(
      FirebaseFirestore.instance,
      config: FirestorePlusConfig(
        defaultCachePolicy: CachePolicy.networkFirst,
        defaultRetryPolicy: const RetryPolicy.exponential(maxAttempts: 3),
        defaultTimeout: const Duration(seconds: 15),
        logger: UiLogger(_print),
        metricsListener: _metrics,
        cacheStore: MemoryCacheStore(maxSize: 200),
      ),
    );
    _users = _firestorePlus.collection<User>(
      'users',
      fromFirestore: User.fromFirestore,
      toFirestore: (user) => user.toFirestore(),
    );
  }

  void _print(String line) {
    debugPrint(line);
    if (mounted) setState(() => _log.add(line));
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _log.clear();
    });
    try {
      await demonstrateFeatures(_firestorePlus, _users, _metrics, _print);
    } catch (e) {
      _print('Demo failed: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('firestore_plus example')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              key: const Key('run-demo'),
              onPressed: _running ? null : _run,
              child: Text(_running ? 'Running…' : 'Run feature demo'),
            ),
          ),
          // Live typed query stream.
          SizedBox(
            height: 56,
            child: StreamBuilder<List<User>>(
              stream: _users.query().orderBy('age').limit(5).snapshots(),
              builder: (context, snap) {
                if (snap.hasError) return Text('Stream error: ${snap.error}');
                final users = snap.data ?? const <User>[];
                return Text('Live: ${users.map((u) => u.name).join(', ')}',
                    textAlign: TextAlign.center);
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _log.length,
              itemBuilder: (_, i) => Text(_log[i],
                  style: const TextStyle(fontFamily: 'monospace')),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// FEATURE DEMONSTRATIONS
// ---------------------------------------------------------------------------

Future<void> demonstrateFeatures(
  FirestorePlus firestorePlus,
  FirestoreCollection<User> users,
  AppMetricsListener metrics,
  void Function(String) print,
) async {
  // ── CRUD ──────────────────────────────────────────────────────────────
  print('═══ CRUD ═══');
  final newDoc = await users.add(
    const User(name: 'Alice', email: 'alice@example.com', age: 30),
  );
  print('Added ${newDoc.id}');

  await users.doc('user-bob').set(
        const User(name: 'Bob', email: 'bob@example.com', age: 25),
      );
  print('Got: ${await users.getById(newDoc.id)}');

  await users.doc(newDoc.id).update({'name': 'Alice Updated', 'age': 31});
  print('Exists after update: ${await users.exists(newDoc.id)}');

  await users.delete(newDoc.id);
  print('After delete getById returns: ${await users.getById(newDoc.id)}');

  // ── Queries ───────────────────────────────────────────────────────────
  print('═══ QUERIES ═══');
  final seed = firestorePlus.batch();
  for (var i = 1; i <= 10; i++) {
    seed.set(
      users.doc('q$i'),
      User(name: 'User $i', email: 'user$i@example.com', age: 20 + i),
    );
  }
  await seed.commit();

  final young = await users
      .query()
      .where('age', isLessThan: 26)
      .orderBy('age')
      .limit(5)
      .get();
  print('Young users: ${young.map((u) => u.name).toList()}');

  final edges = await users
      .query()
      .where(Filter.or(
        Filter('age', isEqualTo: 21),
        Filter('age', isEqualTo: 30),
      ))
      .get();
  print('Filter.or: ${edges.map((u) => u.age).toList()}');
  print('Count: ${await users.query().count()}');

  // ── Cache policies ────────────────────────────────────────────────────
  print('═══ CACHE ═══');
  const cacheFirst = FirestoreOperationOptions(
    cachePolicy: CachePolicy.cacheFirst,
    cacheDuration: Duration(minutes: 5),
  );
  await users.getById('user-bob', options: cacheFirst); // network, cached
  await users.getById('user-bob', options: cacheFirst); // served from cache
  print('cacheFirst twice → metrics: $metrics');

  final swr = await users.getById(
    'user-bob',
    options: const FirestoreOperationOptions(
      cachePolicy: CachePolicy.staleWhileRevalidate,
    ),
  );
  print('staleWhileRevalidate: $swr');

  await firestorePlus.cache.invalidate('users/user-bob');
  await firestorePlus.cache.invalidateCollection('users');
  await firestorePlus.cache.clear();
  print('Cache invalidated & cleared');

  // ── Error handling ────────────────────────────────────────────────────
  print('═══ ERRORS ═══');
  try {
    await users.doc('does-not-exist').update({'age': 1});
  } on FirestorePlusException catch (e) {
    print('Caught ${e.type.name} (code: ${e.code}) at ${e.path}');
  }

  // ── Retry & timeout ───────────────────────────────────────────────────
  print('═══ RETRY & TIMEOUT ═══');
  try {
    await users.getById(
      'user-bob',
      options: const FirestoreOperationOptions(
        cachePolicy: CachePolicy.networkOnly,
        timeout: Duration(microseconds: 1), // force a timeout
        retryPolicy: RetryPolicy(
          maxAttempts: 2,
          initialDelay: Duration(milliseconds: 50),
        ),
      ),
    );
  } on FirestorePlusException catch (e) {
    print('Timed out as expected: ${e.type.name}');
  }

  // ── Pagination ────────────────────────────────────────────────────────
  print('═══ PAGINATION ═══');
  PaginationCursor? cursor;
  var page = 0;
  do {
    final result = await users.query().orderBy('age').paginate(
          limit: 4,
          startAfter: cursor,
          options: const FirestoreOperationOptions(
            cachePolicy: CachePolicy.networkOnly,
          ),
        );
    page++;
    print('Page $page: ${result.items.map((u) => u.age).toList()} '
        'hasMore: ${result.hasMore}');
    cursor = result.hasMore ? result.cursor : null;
  } while (cursor != null);

  // ── Streams ───────────────────────────────────────────────────────────
  print('═══ STREAMS ═══');
  final first = await users.doc('user-bob').snapshots().first;
  print('Document stream first value: $first');

  // ── Transactions ──────────────────────────────────────────────────────
  print('═══ TRANSACTION ═══');
  final newAge = await firestorePlus.runTransaction<int>((tx) async {
    final doc = users.doc('user-bob');
    final user = await tx.get(doc);
    final age = (user?.age ?? 0) + 1;
    tx.update(doc, {'age': age});
    return age;
  });
  print('Bob is now $newAge');

  // ── Cleanup ───────────────────────────────────────────────────────────
  final cleanup = firestorePlus.batch();
  for (var i = 1; i <= 10; i++) {
    cleanup.delete(users.doc('q$i'));
  }
  cleanup.delete(users.doc('user-bob'));
  await cleanup.commit();

  print('═══ DONE — metrics: $metrics ═══');
}
