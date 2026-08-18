import 'log_level.dart';

/// Abstract base class for a logger used by FirestorePlus.
abstract base class FirestorePlusLogger {
  const FirestorePlusLogger();

  /// The current log level threshold.
  FirestoreLogLevel get logLevel;

  /// Logs a message at the given [level].
  void log(
    FirestoreLogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  });

  /// Logs a debug message.
  void debug(String message) => log(FirestoreLogLevel.debug, message);

  /// Logs an info message.
  void info(String message) => log(FirestoreLogLevel.info, message);

  /// Logs a warning message.
  void warning(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) =>
      log(
        FirestoreLogLevel.warning,
        message,
        error: error,
        stackTrace: stackTrace,
      );

  /// Logs an error message.
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) =>
      log(
        FirestoreLogLevel.error,
        message,
        error: error,
        stackTrace: stackTrace,
      );
}

/// A default logger implementation that prints to the console.
final class ConsoleFirestoreLogger extends FirestorePlusLogger {
  @override
  final FirestoreLogLevel logLevel;

  const ConsoleFirestoreLogger({this.logLevel = FirestoreLogLevel.info});

  @override
  void log(
    FirestoreLogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (level.index < logLevel.index) return;

    final prefix = '[FirestorePlus] [${level.name.toUpperCase()}]';
    // ignore: avoid_print
    print('$prefix $message');
    if (error != null) {
      // ignore: avoid_print
      print('$prefix ERROR: $error');
    }
    if (stackTrace != null) {
      // ignore: avoid_print
      print('$prefix STACKTRACE:\n$stackTrace');
    }
  }
}
