import 'dart:async';

import '../cache/cache_manager.dart';
import '../cache/cache_policy.dart';
import '../error/error_mapper.dart';
import '../metrics/firestore_metrics.dart';
import '../retry/retry_executor.dart';
import 'firestore_operation_options.dart';
import 'firestore_plus_config.dart';

/// Internal executor that orchestrates deduplication, cache, retry, and metrics.
class FirestoreOperationExecutor {
  final FirestorePlusConfig config;
  final CacheManager cacheManager;
  final Map<String, Future<Map<String, dynamic>?>> _activeReadRequests = {};

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

    final stopwatch = Stopwatch()..start();
    bool servedFromCache = false;
    int retries = 0;
    Object? finalError;

    try {
      Future<Map<String, dynamic>?> executeWithRetry() async {
        return await RetryExecutor.execute(
          operation: () async {
            if (mergedOptions.timeout != null) {
              return await fetchFromNetwork().timeout(mergedOptions.timeout!);
            } else {
              return await fetchFromNetwork();
            }
          },
          policy: mergedOptions.retryPolicy!,
          logger: config.logger,
          operationName: 'GET $path',
        );
      }

      Future<Map<String, dynamic>?> getOrFetchWithDedupe() async {
        if (!config.enableRequestDeduplication) {
          return await cacheManager.getOrFetch(
            cacheKey: cacheKey,
            policy: mergedOptions.cachePolicy!,
            ttl: mergedOptions.cacheDuration,
            fetchFromNetwork: executeWithRetry,
            operationName: 'GET $path',
          );
        }

        final dedupeKey = 'read:$cacheKey';
        if (_activeReadRequests.containsKey(dedupeKey)) {
          config.logger
              .debug('Deduplicating identical read request for $cacheKey');
          return await _activeReadRequests[dedupeKey]!;
        }

        final future = cacheManager
            .getOrFetch(
          cacheKey: cacheKey,
          policy: mergedOptions.cachePolicy!,
          ttl: mergedOptions.cacheDuration,
          fetchFromNetwork: executeWithRetry,
          operationName: 'GET $path',
        )
            .whenComplete(() {
          _activeReadRequests.remove(dedupeKey);
        });

        _activeReadRequests[dedupeKey] = future;
        return await future;
      }

      final result = await getOrFetchWithDedupe();

      // Determine if it was served from cache purely for metrics (CacheManager logs it internally)
      // A simplistic check: if networkFirst and it succeeded, it wasn't cache (unless network failed)
      // Since CacheManager returns the data directly, we might not know 100% here without modifying CacheManager return type.
      // We will assume it was not served from cache for simplicity unless CacheOnly.
      servedFromCache = mergedOptions.cachePolicy == CachePolicy.cacheOnly;

      return result;
    } catch (e, st) {
      finalError = ErrorMapper.map(e, st, 'GET $path', path);
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
  Future<void> executeWrite({
    required String path,
    required FirestoreOperationType type,
    required FirestoreOperationOptions? options,
    required Future<void> Function() operation,
  }) async {
    final mergedOptions = FirestoreOperationOptions(
      retryPolicy: config.defaultRetryPolicy,
      timeout: config.defaultTimeout,
    ).merge(options);

    final stopwatch = Stopwatch()..start();
    int retries = 0;
    Object? finalError;

    try {
      await RetryExecutor.execute(
        operation: () async {
          if (mergedOptions.timeout != null) {
            await operation().timeout(mergedOptions.timeout!);
          } else {
            await operation();
          }
        },
        policy: mergedOptions.retryPolicy!,
        logger: config.logger,
        operationName: '${type.name.toUpperCase()} $path',
      );
    } catch (e, st) {
      finalError =
          ErrorMapper.map(e, st, '${type.name.toUpperCase()} $path', path);
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
    if (config.metricsListener != null) {
      config.metricsListener!.onOperationComplete(
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
    }
  }
}
