/// Configuration for retrying failed operations.
class RetryPolicy {
  /// The maximum number of retry attempts.
  final int maxAttempts;

  /// The initial delay before the first retry.
  final Duration initialDelay;

  /// The maximum delay between retries.
  final Duration maxDelay;

  /// The multiplier for exponential backoff.
  final double backoffMultiplier;

  /// Whether to apply random jitter to the delay.
  final bool jitter;

  /// An optional callback to determine whether a given error should be retried.
  ///
  /// If provided, this takes precedence over the default retryable error logic.
  /// Return `true` to retry, `false` to throw immediately.
  final bool Function(Object error)? retryIf;

  const RetryPolicy({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 10),
    this.backoffMultiplier = 2.0,
    this.jitter = true,
    this.retryIf,
  });

  /// Returns a policy with no retries.
  const RetryPolicy.none()
      : maxAttempts = 0,
        initialDelay = Duration.zero,
        maxDelay = Duration.zero,
        backoffMultiplier = 1.0,
        jitter = false,
        retryIf = null;

  /// Returns a policy with exponential backoff.
  const RetryPolicy.exponential({
    int maxAttempts = 3,
    Duration initialDelay = const Duration(milliseconds: 500),
    Duration maxDelay = const Duration(seconds: 10),
  }) : this(
          maxAttempts: maxAttempts,
          initialDelay: initialDelay,
          maxDelay: maxDelay,
          backoffMultiplier: 2.0,
          jitter: true,
        );
}
