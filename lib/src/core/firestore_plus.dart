import 'package:cloud_firestore/cloud_firestore.dart';

import '../batch/firestore_batch.dart';
import '../cache/cache_manager.dart';
import '../cache/cache_store.dart';
import '../cache/memory_cache_store.dart';
import '../collection/firestore_collection.dart';
import '../transaction/firestore_transaction.dart';
import 'firestore_operation.dart';
import 'firestore_plus_config.dart';

/// The main entry point for the FirestorePlus package.
class FirestorePlus {
  /// The underlying native [FirebaseFirestore] instance.
  final FirebaseFirestore firestore;

  /// The global configuration for this instance.
  final FirestorePlusConfig config;

  /// The cache store used by this instance.
  late final FirestoreCacheStore cacheStore;

  /// The cache manager used for orchestrating cache policies.
  late final CacheManager cache;

  /// The internal executor for operations.
  late final FirestoreOperationExecutor executor;

  /// Creates a new [FirestorePlus] instance wrapping a [FirebaseFirestore] instance.
  FirestorePlus(
    this.firestore, {
    this.config = const FirestorePlusConfig(),
  }) {
    cacheStore = config.cacheStore ?? MemoryCacheStore();
    cache = CacheManager(cacheStore, config.logger);
    executor = FirestoreOperationExecutor(config: config, cacheManager: cache);
  }

  /// Creates a [FirestoreCollection] reference.
  ///
  /// The [fromFirestore] and [toFirestore] mappers define how the document
  /// is serialized and deserialized.
  FirestoreCollection<T> collection<T>(
    String path, {
    required T Function(Map<String, dynamic> data, String id) fromFirestore,
    required Map<String, dynamic> Function(T instance) toFirestore,
  }) {
    return FirestoreCollection<T>(
      firestore.collection(path),
      this,
      fromFirestore,
      toFirestore,
    );
  }

  /// Creates a write batch, used for performing multiple writes as a single atomic operation.
  FirestoreBatch batch() {
    return FirestoreBatch(firestore.batch(), this);
  }

  /// Executes the given [updateFunction] and then attempts to commit the
  /// changes applied within the transaction.
  Future<T> runTransaction<T>(
    Future<T> Function(FirestoreTransaction transaction) updateFunction, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) async {
    return await firestore.runTransaction<T>((nativeTransaction) async {
      final tx = FirestoreTransaction(nativeTransaction, this);
      return await updateFunction(tx);
    }, timeout: timeout, maxAttempts: maxAttempts);
  }
}
