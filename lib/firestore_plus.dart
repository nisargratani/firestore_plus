/// Production-ready utilities on top of `cloud_firestore`: typed
/// collections, application-level caching with policies and TTL, retry with
/// backoff, timeouts, normalized errors, request deduplication, pagination,
/// batches, transactions, logging and metrics.
///
/// Start by wrapping a `FirebaseFirestore` instance in a `FirestorePlus`:
///
/// ```dart
/// final firestorePlus = FirestorePlus(FirebaseFirestore.instance);
/// final users = firestorePlus.collection<User>(
///   'users',
///   fromFirestore: User.fromFirestore,
///   toFirestore: (user) => user.toFirestore(),
/// );
/// final user = await users.getById('user-1'); // null if missing
/// ```
library;

// Core
export 'src/core/data_source.dart';
export 'src/core/firestore_plus.dart';
export 'src/core/firestore_plus_config.dart';
export 'src/core/firestore_operation_options.dart';

// Collection / Document / Query
export 'src/collection/firestore_collection.dart';
export 'src/collection/firestore_document.dart';
export 'src/collection/firestore_query.dart';

// Cache
export 'src/cache/cache_manager.dart';
export 'src/cache/cache_store.dart';
export 'src/cache/memory_cache_store.dart';
export 'src/cache/cache_policy.dart';

// Error
export 'src/error/firestore_plus_exception.dart';
export 'src/error/error_mapper.dart';

// Logging
export 'src/logging/log_level.dart';
export 'src/logging/firestore_plus_logger.dart';

// Metrics
export 'src/metrics/firestore_metrics.dart';

// Pagination
export 'src/pagination/pagination.dart';

// Retry
export 'src/retry/retry_policy.dart';
export 'src/retry/retry_executor.dart';

// Batch & Transaction
export 'src/batch/firestore_batch.dart';
export 'src/transaction/firestore_transaction.dart';
