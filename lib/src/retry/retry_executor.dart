import 'dart:async';
import 'dart:math' as math;

import '../logging/firestore_plus_logger.dart';
import 'retry_policy.dart';
import '../error/error_mapper.dart';

/// Utility class for executing operations with retry logic.
class RetryExecutor {
  /// Executes the given [operation] according to the [policy].
  static Future<T> execute<T>({
    required Future<T> Function() operation,
    required RetryPolicy policy,
    required FirestorePlusLogger logger,
    String? operationName,
  }) async {
    int attempts = 0;
    final random = policy.jitter ? math.Random() : null;

    while (true) {
      attempts++;
      try {
        return await operation();
      } catch (e, st) {
        // If we exceeded max attempts, throw immediately
        if (attempts > policy.maxAttempts) {
          logger.warning(
              'Operation ${operationName ?? 'unknown'} failed after $attempts attempts.',
              error: e,
              stackTrace: st);
          throw ErrorMapper.map(e, st, operationName);
        }

        // Determine retryability: user-provided retryIf takes precedence
        final bool shouldRetry;
        if (policy.retryIf != null) {
          shouldRetry = policy.retryIf!(e);
        } else {
          shouldRetry = ErrorMapper.isRetryable(e);
        }

        if (!shouldRetry) {
          logger.debug(
              'Operation ${operationName ?? 'unknown'} failed with non-retryable error.');
          throw ErrorMapper.map(e, st, operationName);
        }

        // Calculate delay with exponential backoff
        final int delayMs = (policy.initialDelay.inMilliseconds *
                math.pow(policy.backoffMultiplier, attempts - 1))
            .toInt();

        final Duration baseDelay = Duration(
          milliseconds: math.min(delayMs, policy.maxDelay.inMilliseconds),
        );

        // Apply jitter if enabled (randomize between 50% and 100% of base delay)
        Duration finalDelay = baseDelay;
        if (random != null && baseDelay.inMilliseconds > 0) {
          final int jitterMs = (baseDelay.inMilliseconds * 0.5).toInt() +
              random.nextInt((baseDelay.inMilliseconds * 0.5).toInt());
          finalDelay = Duration(milliseconds: jitterMs);
        }

        logger.debug(
            'Retry $attempts/${policy.maxAttempts} for ${operationName ?? 'unknown'} in ${finalDelay.inMilliseconds}ms due to: $e');

        await Future.delayed(finalDelay);
      }
    }
  }
}
