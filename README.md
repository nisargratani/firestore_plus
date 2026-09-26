# firestore_plus

Production-ready Firestore utilities for Flutter — caching, retry, error handling, pagination, logging, transactions, batch operations and more.

`firestore_plus` acts as an application-level infrastructure wrapper on top of `cloud_firestore`. It doesn't replace the native Firebase capabilities but enhances them to give you robust, typed, and predictable data access.

## Features

- **Typed Collections & Documents**: Full support for `.fromFirestore` and `.toFirestore` — no code generation required.
- **Intelligent Caching**: Advanced cache policies (`networkFirst`, `cacheFirst`, `staleWhileRevalidate`, `networkOnly`, `cacheOnly`) with TTL and LRU eviction.
- **Resilient Retries**: Configurable exponential backoff and jitter for transient failures with a custom `retryIf` callback.
- **Error Normalization**: Maps native `FirebaseException`s into predictable `FirestorePlusException`s.
- **Request Deduplication**: Coalesces identical concurrent read requests to save network calls.
- **Transactions & Batching**: Safe wrappers that maintain your models' type-safety.
- **Observability**: Built-in structured logging and metrics listeners.
- **Cursor-based Pagination**: Type-safe pagination utilities that respect native cursor semantics.
- **Timeouts**: Per-operation and global timeout enforcement.
- **Pluggable Caching**: Bring your own persistent cache implementation via the `FirestoreCacheStore` interface.

## Why firestore_plus?

`cloud_firestore` is a fantastic real-time database, but for a production application, you often need to handle flaky networks, memory caching to prevent excessive reads, timeout enforcement, and predictable error mapping. `firestore_plus` implements these best practices out-of-the-box so you can focus on building your app.

## Installation

Add `firestore_plus` to your `pubspec.yaml`:

```yaml
dependencies:
  firestore_plus: ^0.0.3
```

Then run:

```bash
flutter pub get
```

Requires Flutter 3.27+ / Dart 3.6+ (the minimum supported by `cloud_firestore` 6.x). `firestore_plus` supports every platform `cloud_firestore` supports (Android, iOS, macOS, web, Windows).

A runnable app that exercises every feature against the Firestore emulator lives in [`example/`](example/).

## Quick Start

### Initialization

Initialize Firebase as usual (see the [FlutterFire docs](https://firebase.google.com/docs/flutter/setup)), then wrap the Firestore instance:

```dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firestore_plus/firestore_plus.dart';

await Firebase.initializeApp(/* options */);

final firestorePlus = FirestorePlus(
  FirebaseFirestore.instance,
  config: const FirestorePlusConfig(
    defaultCachePolicy: CachePolicy.networkFirst,
    defaultTimeout: Duration(seconds: 15),
  ),
);
```

### Typed Models

```dart
class User {
  final String id;
  final String name;
  final int age;

  User({required this.id, required this.name, this.age = 0});

  factory User.fromFirestore(Map<String, dynamic> data, String id) {
    return User(
      id: id,
      name: data['name'] as String,
      age: data['age'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toFirestore() => {'name': name, 'age': age};
}

final users = firestorePlus.collection<User>(
  'users',
  fromFirestore: User.fromFirestore,
  toFirestore: (user) => user.toFirestore(),
);
```

## CRUD

```dart
// Add
final newDoc = await users.add(User(id: '', name: 'Alice'));

// Get by ID (returns null if the document does not exist)
final user = await users.getById(newDoc.id);

// Set (with specific ID)
await users.doc('user-1').set(User(id: 'user-1', name: 'Bob'));

// Update (throws FirestorePlusException of type notFound if missing)
await users.doc(newDoc.id).update({'name': 'Alice Updated'});

// Check existence
final exists = await users.exists(newDoc.id);

// Count
final count = await users.query().count();

// Delete
await users.delete(newDoc.id);
```

## Queries

```dart
final results = await users
  .query()
  .where('age', isGreaterThan: 21)
  .orderBy('age')
  .limit(10)
  .get();
```

Supported query operations: `where`, `whereIn`, `whereNotIn`, `arrayContains`, `arrayContainsAny`, `isNull`, `isEqualTo`, `isNotEqualTo`, `isGreaterThan`, `isGreaterThanOrEqualTo`, `isLessThan`, `isLessThanOrEqualTo`, `orderBy`, `limit`, `limitToLast`, `startAt`, `startAfter`, `endAt`, `endBefore`, `startAtDocument`, `startAfterDocument`, `endAtDocument`, `endBeforeDocument`, `count`.

Composite `OR` queries use the native `Filter` class:

```dart
final result = await users
  .query()
  .where(Filter.or(
    Filter('age', isLessThan: 18),
    Filter('age', isGreaterThan: 65),
  ))
  .get();
```

**Native query escape hatch**: Access the underlying `Query` via `query.nativeQuery` at any time.

## Caching

Override global config per-operation:

```dart
final user = await users.getById('someId',
  options: const FirestoreOperationOptions(
    cachePolicy: CachePolicy.cacheFirst,
    cacheDuration: Duration(minutes: 5),
  ),
);
```

### Cache Policies

| Policy | Behavior |
|---|---|
| `networkOnly` | Always fetch from network. Updates cache. |
| `cacheFirst` | Return cached data if available; otherwise fetch from network. |
| `cacheOnly` | Return cached data only; never fetch from network. |
| `networkFirst` | Fetch from network; if it fails, fall back to cache. |
| `staleWhileRevalidate` | Return cached data immediately; refresh in the background. On a cache miss, behaves like a normal network read (errors are thrown). |

The default policy is `networkFirst`. By default cache entries have no TTL (`defaultCacheDuration: null`) and live until evicted, invalidated or overwritten.

### TTL

Set a time-to-live on cache entries:

```dart
options: const FirestoreOperationOptions(
  cacheDuration: Duration(minutes: 10),
),
```

After the TTL expires, the next `cacheFirst` request will fetch fresh data from the network.

### Cache Invalidation

```dart
// Invalidate a specific document
await firestorePlus.cache.invalidate('users/user-1');

// Invalidate an entire collection
await firestorePlus.cache.invalidateCollection('users');

// Clear the entire cache
await firestorePlus.cache.clear();
```

Writes made through `firestore_plus` (`add`, `set`, `update`, `delete`, batches and transactions) automatically invalidate the cached document **and** the cached query results of its collection. Writes made outside the package (native SDK, other devices, Cloud Functions) are not observed — use TTLs, `networkFirst`, or streams for data that changes remotely.

If a document no longer exists on the server, its cache entry is removed on the next network read.

## Retry

Configure retry behavior globally or per-operation:

```dart
const retryPolicy = RetryPolicy(
  maxAttempts: 3,
  initialDelay: Duration(milliseconds: 500),
  maxDelay: Duration(seconds: 5),
  backoffMultiplier: 2.0,
  jitter: true,
);

final user = await users.getById('id',
  options: FirestoreOperationOptions(retryPolicy: retryPolicy),
);
```

Named constructors for common cases:

```dart
const RetryPolicy.exponential(maxAttempts: 3)
const RetryPolicy.none()  // Never retry
```

**Custom retry predicate:**

```dart
RetryPolicy(
  maxAttempts: 5,
  retryIf: (error) {
    if (error is FirestorePlusException) {
      return error.type == FirestoreErrorType.timeout;
    }
    return false;
  },
)
```

`maxAttempts` is the number of **retries** after the first attempt, so `maxAttempts: 3` means up to 4 attempts in total.

**Retryable errors** (by default): `network`, `unavailable`, `timeout`, `resourceExhausted`.
**Non-retryable errors** (never retried by default): `permissionDenied`, `notFound`, `invalidArgument`, `alreadyExists`, `cancelled`, `serialization`, `unknown`.

**Writes and timeouts:** a write that times out is still queued by Firestore and may commit later. To avoid applying it twice (for example a `FieldValue.increment`), `set`, `update`, `delete` and `add` do **not** retry timeouts by default. Supply your own `retryIf` if you want different behaviour.

## Error Handling

Firestore errors from reads, writes, queries, streams, batches and transactions are normalized into `FirestorePlusException`:

```dart
try {
  await users.getById('user-1');
} on FirestorePlusException catch (e) {
  print(e.type);               // e.g. FirestoreErrorType.permissionDenied
  print(e.message);            // descriptive message
  print(e.code);               // original Firebase error code, e.g. 'permission-denied'
  print(e.operation);          // 'GET users/user-1'
  print(e.path);               // 'users/user-1'
  print(e.originalException);  // the original FirebaseException
  print(e.stackTrace);         // original stack trace
}
```

A missing document is **not** an error: `get`/`getById` return `null`. `update` on a missing document throws with type `notFound`. Exceptions you throw yourself inside `runTransaction` are rethrown unchanged.

Error types: `network`, `unavailable`, `timeout`, `permissionDenied`, `notFound`, `invalidArgument`, `alreadyExists`, `cancelled`, `resourceExhausted`, `serialization`, `unknown`.

## Logging

Built-in structured logging with configurable levels:

```dart
final firestorePlus = FirestorePlus(
  FirebaseFirestore.instance,
  config: FirestorePlusConfig(
    logger: const ConsoleFirestoreLogger(logLevel: FirestoreLogLevel.debug),
  ),
);
```

Output format:

```
[FirestorePlus] [DEBUG] Cache Policy: cacheFirst for users/user-1
[FirestorePlus] [DEBUG] CACHE HIT for users/user-1
[FirestorePlus] [DEBUG] Retry 1/3 for GET users in 250ms due to: ...
```

**Custom logger**: Extend `FirestorePlusLogger`:

```dart
final class MyLogger extends FirestorePlusLogger {
  @override
  FirestoreLogLevel get logLevel => FirestoreLogLevel.info;

  @override
  void log(FirestoreLogLevel level, String message,
      {Object? error, StackTrace? stackTrace}) {
    // Send to your logging service
  }
}
```

Document data is **never** logged by default.

## Timeouts

Per-operation:

```dart
await users.getById('id',
  options: const FirestoreOperationOptions(
    timeout: Duration(seconds: 5),
  ),
);
```

Global default:

```dart
const FirestorePlusConfig(
  defaultTimeout: Duration(seconds: 15),
)
```

Timeout errors throw `FirestorePlusException` with `FirestoreErrorType.timeout`. The timeout applies to each attempt, so with retries the total time can exceed it. Batches and transactions use native Firestore semantics (`runTransaction` has its own `timeout` parameter).

## Pagination

Cursor-based pagination using native Firestore cursor semantics:

```dart
final page1 = await users
  .query()
  .orderBy('createdAt', descending: true)
  .paginate(limit: 20);

print('Items: ${page1.items.length}');
print('Has more: ${page1.hasMore}');

// Next page
if (page1.hasMore && page1.cursor != null) {
  final page2 = await users
    .query()
    .orderBy('createdAt', descending: true)
    .paginate(limit: 20, startAfter: page1.cursor);
}
```

`PaginatedResult<T>` provides: `items`, `hasMore`, `cursor`. `hasMore` is exact: the query fetches `limit + 1` documents to find out whether another page exists. `limit` must be greater than 0.

## Streams

Typed real-time streams for documents and queries:

```dart
// Document stream
final stream = users.doc('user-1').snapshots();
stream.listen((User? user) {
  print('Updated: $user');
});

// Query stream
final queryStream = users
  .query()
  .where('age', isGreaterThan: 21)
  .snapshots();
queryStream.listen((List<User> users) {
  print('${users.length} users');
});
```

Stream errors (e.g. `permission-denied`) and serialization errors are emitted as `FirestorePlusException`. Streams are not cached. Cancel your subscriptions (or let `StreamBuilder` do it) when a widget is disposed.

## Batch Operations

```dart
final batch = firestorePlus.batch();
batch.set(users.doc('1'), User(id: '1', name: 'One'));
batch.set(users.doc('2'), User(id: '2', name: 'Two'));
batch.update(users.doc('3'), {'name': 'Three Updated'});
batch.delete(users.doc('4'));
await batch.commit();
```

Cache is automatically invalidated for all affected documents after a successful commit. Access the native `WriteBatch` via `batch.nativeBatch`.

## Transactions

```dart
await firestorePlus.runTransaction<void>((tx) async {
  final doc = users.doc('user-1');
  final user = await tx.get(doc);
  if (user != null) {
    tx.update(doc, {'age': user.age + 1});
  }
});
```

Firestore transaction semantics are preserved. No unsafe retry logic is added on top of native transaction retries. Documents written in the transaction are invalidated in the cache once it commits. Access the native `Transaction` via `tx.nativeTransaction`.

## Request Deduplication

When enabled (default), identical concurrent read requests are coalesced into a single Firestore call:

```dart
// These three concurrent reads result in ONE Firestore request:
final results = await Future.wait([
  users.getById('user-1'),
  users.getById('user-1'),
  users.getById('user-1'),
]);
```

Disable via config:

```dart
const FirestorePlusConfig(
  enableRequestDeduplication: false,
)
```

## Metrics

Track operation stats with a custom metrics listener:

```dart
class AppMetricsListener implements FirestoreMetricsListener {
  @override
  void onOperationComplete(FirestoreOperationMetrics metrics) {
    print('${metrics.type}: ${metrics.duration.inMilliseconds}ms');
  }
}

final firestorePlus = FirestorePlus(
  FirebaseFirestore.instance,
  config: FirestorePlusConfig(
    metricsListener: AppMetricsListener(),
  ),
);
```

`FirestoreOperationMetrics` provides: `type`, `path`, `duration`, `servedFromCache`, `isSuccess`, `retryCount`, `error`.

Metrics are emitted for document reads (`get`), query reads and pagination (`query`), `add`, `set`, `update`, `delete`, `exists` and `count`. Batches, transactions and streams do not emit metrics. An exception thrown by your listener is logged and never fails the operation.

Metrics remain local. Nothing is sent externally.

## Custom Cache Store

Implement `FirestoreCacheStore` for persistent caching (e.g., Hive, SQLite):

```dart
class HiveCacheStore implements FirestoreCacheStore {
  @override
  Future<CacheEntry<Map<String, dynamic>>?> get(String key) async { /* ... */ }

  @override
  Future<void> put(String key, Map<String, dynamic> value, {Duration? ttl}) async { /* ... */ }

  @override
  Future<void> remove(String key) async { /* ... */ }

  @override
  Future<void> clear() async { /* ... */ }

  @override
  Future<void> clearCollection(String collection) async { /* ... */ }
}

final firestorePlus = FirestorePlus(
  FirebaseFirestore.instance,
  config: FirestorePlusConfig(
    cacheStore: HiveCacheStore(),
  ),
);
```

Keys are either a document path (`users/u1`) or a query key starting with `<collection>?` (e.g. `users?q=...`). Writes invalidate query keys created during the current app session; query results persisted by a previous session are not tracked, so give them a TTL or call `invalidateCollection` at startup. `clearCollection('users')` must remove keys starting with `users/` and `users?`. Values are raw Firestore data and may contain `Timestamp`, `GeoPoint`, `DocumentReference` or `Blob` — a persistent store must encode these itself.

The built-in `MemoryCacheStore` supports configurable `maxSize` (default 500 entries) with LRU eviction, and copies values so mutating a returned object never corrupts the cache.

## Testing

The package is designed for testability. Use `fake_cloud_firestore` for unit tests:

```dart
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firestore_plus/firestore_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('example test', () async {
    final fakeFirestore = FakeFirebaseFirestore();
    final firestorePlus = FirestorePlus(
      fakeFirestore,
      config: const FirestorePlusConfig(
        defaultCachePolicy: CachePolicy.networkOnly,
        defaultRetryPolicy: RetryPolicy.none(),
      ),
    );

    final users = firestorePlus.collection<User>(
      'users',
      fromFirestore: User.fromFirestore,
      toFirestore: (user) => user.toFirestore(),
    );

    await users.doc('1').set(User(id: '1', name: 'Test'));
    final user = await users.getById('1');
    expect(user!.name, 'Test');
  });
}
```

## Offline Firestore vs Application Cache

`cloud_firestore` already offers local offline persistence. `firestore_plus` provides an **Application Cache** which sits on top of Firestore and helps prevent redundant network reads within your app's lifecycle, reducing billable reads and improving UI responsiveness without relying solely on Firestore's native cache engine.

| | Native Firestore Offline | firestore_plus Cache |
|---|---|---|
| **Scope** | SDK-level persistence | Application-level read caching |
| **Purpose** | Offline access & sync | Reduce reads & improve responsiveness |
| **Configured by** | FirebaseFirestore settings | FirestorePlusConfig |
| **Policies** | Automatic | networkFirst, cacheFirst, etc. |
| **TTL** | No | Yes |
| **Eviction** | SDK-managed | Configurable (maxSize, TTL) |

## Performance & Best Practices

- Use `CachePolicy.cacheFirst` for data that rarely changes to minimize reads.
- Use `CachePolicy.staleWhileRevalidate` for data that should feel instant but stay fresh.
- Set reasonable TTLs to avoid serving stale data indefinitely.
- Configure `MemoryCacheStore(maxSize:)` based on your app's memory budget.
- Enable request deduplication (default) to avoid redundant reads from concurrent widgets.
- Use `RetryPolicy.none()` in tests for faster execution.
- Avoid caching paginated results — use `CachePolicy.networkOnly` for pagination.

## Migration from cloud_firestore

`firestore_plus` is additive. You don't need to migrate everything at once:

1. Add `firestore_plus` as a dependency.
2. Create a `FirestorePlus` instance wrapping your existing `FirebaseFirestore.instance`.
3. Gradually convert collections to use `firestore.collection<T>(...)`.
4. Your existing `cloud_firestore` code continues to work alongside `firestore_plus`.
5. Access native references at any time via `nativeRef`, `nativeQuery`, `nativeBatch`, `nativeTransaction`.

## FAQ

**Does this replace `cloud_firestore`?**
No. `firestore_plus` is built on top of `cloud_firestore` and requires it.

**Does this handle Firebase authentication?**
No. This package is focused exclusively on Firestore data access.

**Does this send any analytics or telemetry?**
No. Metrics remain local unless you explicitly connect a listener.

**Can I use this with Riverpod / Bloc / Provider?**
Yes. `firestore_plus` is state-management agnostic. It provides data access utilities that work with any architecture.

**Does this provide Firestore security rules?**
No. Security rules are the responsibility of your Firebase project.

## Limitations

- Subcollections are not directly modeled — use `firestore.collection<T>('parent/docId/subcollection', ...)`.
- `staleWhileRevalidate` background fetch errors (on a cache hit) are logged but not propagated to the caller.
- When a paginated page is served from the application cache, the cursor is rebuilt by reading the last document (from Firestore's local cache when possible).
- The application cache only sees writes made through `firestore_plus`.
- `fake_cloud_firestore` has limited support for `startAfterDocument` pagination in tests.

## Roadmap

- Aggregate query support (sum, average)
- Subcollection helper API
- Offline queue for pending writes
- Built-in rate limiting
- Cache statistics dashboard
- Hive/SQLite cache store packages

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Write tests for new functionality
4. Ensure `dart analyze` and `dart format` pass
5. Submit a pull request

## License

MIT — see [LICENSE](LICENSE) for details.
