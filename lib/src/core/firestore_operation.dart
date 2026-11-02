import 'dart:async';

import '../cache/cache_manager.dart';
import '../error/error_mapper.dart';
import '../error/firestore_plus_exception.dart';
import '../metrics/firestore_metrics.dart';
import '../retry/retry_executor.dart';
import '../retry/retry_policy.dart';
import 'data_source.dart';
import 'firestore_operation_options.dart';
import 'firestore_plus_config.dart';

typedef _ReadResult = ({Map<String, dynamic>? data, DataSource source});

/// Internal executor that orchestrates deduplication, cache, retry, and metrics.
class FirestoreOperationExecutor {
  final FirestorePlusConfig config;
  final CacheManager cacheManager;
  final Map<String, ({Future<_ReadResult> result, PendingRead read})>
      _activeReadRequests = {};

  /// Creates an executor. Internal to `FirestorePlus`; not intended for
  /// direct use.
  FirestoreOperationExecutor({
    required this.config,
    required this.cacheManager,
  });

  /// Executes a read operation that returns data capable of being cached.
  ///
  /// [type] is reported in metrics: [FirestoreOperationType.get] for document
  /// reads, [FirestoreOperationType.query] for query reads.
  Future<Map<String, dynamic>?> executeRead({
    required String path,
    required String cacheKey,
    required FirestoreOperationOptions? options,
    required Future<Map<String, dynamic>?> Function() fetchFromNetwork,
    FirestoreOperationType type = FirestoreOperationType.get,
  }) async {
    final mergedOptions = FirestoreOperationOptions(
      cachePolicy: config.defaultCachePolicy,
      cacheDuration: config.defaultCacheDuration,
      retryPolicy: config.defaultRetryPolicy,
      timeout: config.defaultTimeout,
    ).merge(options);

    final operationName = 'GET $path';
    final stopwatch = Stopwatch()..start();
    bool servedFromCache = false;
    int retries = 0;
    FirestorePlusException? finalError;

    try {
      Future<Map<String, dynamic>?> executeWithRetry() {
        return RetryExecutor.execute(
          operation: () {
            final timeout = mergedOptions.timeout;
            return timeout != null
                ? fetchFromNetwork().timeout(timeout)
                : fetchFromNetwork();
          },
          policy: mergedOptions.retryPolicy!,
          logger: config.logger,
          operationName: operationName,
          path: path,
          onRetry: (n) => retries = n,
        );
      }

      Future<_ReadResult> fetch() => cacheManager.getOrFetchWithSource(
            cacheKey: cacheKey,
            policy: mergedOptions.cachePolicy!,
            ttl: mergedOptions.cacheDuration,
            fetchFromNetwork: executeWithRetry,
            operationName: operationName,
          );

      final _ReadResult result;
      if (!config.enableRequestDeduplication) {
        result = await fetch();
      } else {
        // The policy is part of the key: a cacheOnly read must never hand its
        // result to a concurrent networkOnly read, and vice versa.
        final dedupeKey = 'read:${mergedOptions.cachePolicy!.name}:$cacheKey';
        final active = _activeReadRequests[dedupeKey];
        // Read-your-writes: a read must not join one that started before the
        // key was last invalidated (e.g. by a write that has completed since).
        if (active != null && !active.read.invalidated) {
          config.logger
              .debug('Deduplicating identical read request for $cacheKey');
          result = await active.result;
        } else {
          final read = cacheManager.beginRead(cacheKey);
          final future = fetch().whenComplete(() {
            cacheManager.endRead(read);
            // An older read finishing must not drop a newer read's entry.
            if (identical(_activeReadRequests[dedupeKey]?.read, read)) {
              _activeReadRequests.remove(dedupeKey);
            }
          });
          _activeReadRequests[dedupeKey] = (result: future, read: read);
          result = await future;
        }
      }

      // A cacheOnly miss returns no data: nothing was served from cache.
      servedFromCache =
          result.source != DataSource.network && result.data != null;
      return result.data;
    } catch (e, st) {
      final mapped = ErrorMapper.map(e, st, operationName, path);
      finalError = mapped;
      throw mapped;
    } finally {
      stopwatch.stop();
      _emitMetrics(
        type: type,
        path: path,
        duration: stopwatch.elapsed,
        servedFromCache: servedFromCache,
        isSuccess: finalError == null,
        retryCount: retries,
        error: finalError,
      );
    }
  }

  /// Executes a generic operation (write, delete, etc.) without cache logic, but with retry and timeout.
  ///
  /// When [retryOnTimeout] is false, timeouts (including `deadline-exceeded`)
  /// are never retried, whatever the policy's `retryIf` says: a timed-out
  /// write is still queued by Firestore and may commit later, so retrying
  /// could apply it twice (e.g. an increment). `retryIf` still decides for
  /// every other error.
  Future<void> executeWrite({
    required String path,
    required FirestoreOperationType type,
    required FirestoreOperationOptions? options,
    required Future<void> Function() operation,
    bool retryOnTimeout = true,
  }) async {
    final mergedOptions = FirestoreOperationOptions(
      retryPolicy: config.defaultRetryPolicy,
      timeout: config.defaultTimeout,
    ).merge(options);

    final operationName = '${type.name.toUpperCase()} $path';
    final stopwatch = Stopwatch()..start();
    int retries = 0;
    FirestorePlusException? finalError;

    var policy = mergedOptions.retryPolicy!;
    if (!retryOnTimeout) {
      final userRetryIf = policy.retryIf;
      policy = RetryPolicy(
        maxAttempts: policy.maxAttempts,
        initialDelay: policy.initialDelay,
        maxDelay: policy.maxDelay,
        backoffMultiplier: policy.backoffMultiplier,
        jitter: policy.jitter,
        retryIf: (e) =>
            ErrorMapper.map(e).type != FirestoreErrorType.timeout &&
            (userRetryIf?.call(e) ?? ErrorMapper.isRetryable(e)),
      );
    }

    try {
      await RetryExecutor.execute(
        operation: () {
          final timeout = mergedOptions.timeout;
          return timeout != null ? operation().timeout(timeout) : operation();
        },
        policy: policy,
        logger: config.logger,
        operationName: operationName,
        path: path,
        onRetry: (n) => retries = n,
      );
    } catch (e, st) {
      final mapped = ErrorMapper.map(e, st, operationName, path);
      finalError = mapped;
      throw mapped;
    } finally {
      stopwatch.stop();
      _emitMetrics(
        type: type,
        path: path,
        duration: stopwatch.elapsed,
        servedFromCache: false,
        isSuccess: finalError == null,
        retryCount: retries,
        error: finalError,
      );
    }
  }

  void _emitMetrics({
    required FirestoreOperationType type,
    required String path,
    required Duration duration,
    required bool servedFromCache,
    required bool isSuccess,
    required int retryCount,
    required Object? error,
  }) {
    final listener = config.metricsListener;
    if (listener == null) return;
    try {
      listener.onOperationComplete(
        FirestoreOperationMetrics(
          type: type,
          path: path,
          duration: duration,
          servedFromCache: servedFromCache,
          isSuccess: isSuccess,
          retryCount: retryCount,
          error: error,
        ),
      );
    } catch (e, st) {
      // A faulty listener must not turn a successful operation into a failure.
      config.logger.warning('Metrics listener threw', error: e, stackTrace: st);
    }
  }
}
