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
  final Map<String, Future<_ReadResult>> _activeReadRequests = {};

  FirestoreOperationExecutor({
    required this.config,
    required this.cacheManager,
  });

  /// Executes a read operation that returns data capable of being cached.
  Future<Map<String, dynamic>?> executeRead({
    required String path,
    required String cacheKey,
    required FirestoreOperationOptions? options,
    required Future<Map<String, dynamic>?> Function() fetchFromNetwork,
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
    Object? finalError;

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
        final inFlight = _activeReadRequests[dedupeKey];
        if (inFlight != null) {
          config.logger
              .debug('Deduplicating identical read request for $cacheKey');
          result = await inFlight;
        } else {
          final future = fetch().whenComplete(() {
            _activeReadRequests.remove(dedupeKey);
          });
          _activeReadRequests[dedupeKey] = future;
          result = await future;
        }
      }

      servedFromCache = result.source != DataSource.network;
      return result.data;
    } catch (e, st) {
      finalError = ErrorMapper.map(e, st, operationName, path);
      throw finalError;
    } finally {
      stopwatch.stop();
      _emitMetrics(
        type: FirestoreOperationType.get,
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
  /// When [retryOnTimeout] is false and the policy has no custom `retryIf`,
  /// timeouts are not retried: a timed-out write is still queued by Firestore
  /// and may commit later, so retrying could apply it twice (e.g. an
  /// increment).
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
    Object? finalError;

    var policy = mergedOptions.retryPolicy!;
    if (!retryOnTimeout && policy.retryIf == null) {
      policy = RetryPolicy(
        maxAttempts: policy.maxAttempts,
        initialDelay: policy.initialDelay,
        maxDelay: policy.maxDelay,
        backoffMultiplier: policy.backoffMultiplier,
        jitter: policy.jitter,
        retryIf: (e) =>
            ErrorMapper.isRetryable(e) &&
            ErrorMapper.map(e).type != FirestoreErrorType.timeout,
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
      finalError = ErrorMapper.map(e, st, operationName, path);
      throw finalError;
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
