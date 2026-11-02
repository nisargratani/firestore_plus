import 'dart:async';
import 'dart:math' as math;

import '../logging/firestore_plus_logger.dart';
import 'retry_policy.dart';
import '../error/error_mapper.dart';
import '../error/firestore_plus_exception.dart';

/// Utility class for executing operations with retry logic.
class RetryExecutor {
  /// Executes the given [operation] according to the [policy].
  ///
  /// [onRetry] is invoked with the retry number (starting at 1) before each
  /// retry. [path] is attached to the thrown [FirestorePlusException] and to
  /// the exception passed to [RetryPolicy.retryIf].
  static Future<T> execute<T>({
    required Future<T> Function() operation,
    required RetryPolicy policy,
    required FirestorePlusLogger logger,
    String? operationName,
    String? path,
    void Function(int retry)? onRetry,
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
          if (policy.maxAttempts > 0) {
            logger.warning(
                'Operation ${operationName ?? 'unknown'} failed after $attempts attempts.',
                error: e,
                stackTrace: st);
          }
          throw ErrorMapper.map(e, st, operationName, path);
        }

        // Determine retryability: user-provided retryIf takes precedence. It
        // receives the normalized FirestorePlusException, like every other
        // error the package reports (the raw error is in originalException).
        final retryIf = policy.retryIf;
        final bool shouldRetry = retryIf != null
            ? retryIf(ErrorMapper.map(e, st, operationName, path))
            : ErrorMapper.isRetryable(e);

        if (!shouldRetry) {
          logger.debug(
              'Operation ${operationName ?? 'unknown'} failed with non-retryable error.');
          throw ErrorMapper.map(e, st, operationName, path);
        }

        final finalDelay = _delayFor(policy, attempts, random);

        logger.debug(
            'Retry $attempts/${policy.maxAttempts} for ${operationName ?? 'unknown'} in ${finalDelay.inMilliseconds}ms due to: $e');

        onRetry?.call(attempts);
        await Future.delayed(finalDelay);
      }
    }
  }

  static Duration _delayFor(
      RetryPolicy policy, int attempt, math.Random? random) {
    final maxMs = math.max(0, policy.maxDelay.inMilliseconds);

    // Exponential backoff, computed in doubles and clamped before converting
    // so large attempt counts cannot overflow.
    double rawMs = policy.initialDelay.inMilliseconds *
        math.pow(policy.backoffMultiplier, attempt - 1).toDouble();
    if (rawMs.isNaN || rawMs < 0) rawMs = 0;
    final baseMs = rawMs > maxMs ? maxMs : rawMs.round();

    // Jitter: randomize between 50% and 100% of the base delay.
    if (random != null && baseMs > 0) {
      final half = baseMs ~/ 2;
      return Duration(milliseconds: baseMs - random.nextInt(half + 1));
    }
    return Duration(milliseconds: baseMs);
  }
}
