/// Represents the internal categories of errors that FirestorePlus handles.
enum FirestoreErrorType {
  /// The network is unavailable.
  network,

  /// The requested resource is unavailable.
  unavailable,

  /// The operation timed out.
  timeout,

  /// The user does not have permission to execute the operation.
  permissionDenied,

  /// The requested document was not found.
  notFound,

  /// An invalid argument was provided.
  invalidArgument,

  /// The document already exists.
  alreadyExists,

  /// The operation was cancelled.
  cancelled,

  /// Resources are exhausted (e.g., quota exceeded).
  resourceExhausted,

  /// An error occurred during serialization.
  serialization,

  /// An unknown or unmapped error occurred.
  unknown,
}

/// Base exception class for all errors thrown by FirestorePlus.
class FirestorePlusException implements Exception {
  /// The mapped error type.
  final FirestoreErrorType type;

  /// A descriptive error message.
  final String message;

  /// The original exception (e.g., `FirebaseException`).
  final Object? originalException;

  /// The stack trace where the error occurred.
  final StackTrace? stackTrace;

  /// The operation being performed when the error occurred.
  final String? operation;

  /// The path of the document or collection involved.
  final String? path;

  /// The error code, usually mapping to the original `FirebaseException.code`.
  final String? code;

  /// Creates an exception. Normally produced by `ErrorMapper.map`.
  const FirestorePlusException({
    required this.type,
    required this.message,
    this.originalException,
    this.stackTrace,
    this.operation,
    this.path,
    this.code,
  });

  @override
  String toString() {
    return 'FirestorePlusException(type: $type, code: $code, message: $message, operation: $operation, path: $path)';
  }
}
