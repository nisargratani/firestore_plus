import 'package:firebase_core/firebase_core.dart';
import 'dart:async';
import 'firestore_plus_exception.dart';

/// Utilities for mapping native exceptions to [FirestorePlusException].
class ErrorMapper {
  /// Maps a given [error] to a [FirestorePlusException].
  static FirestorePlusException map(Object error,
      [StackTrace? stackTrace, String? operation, String? path]) {
    if (error is FirestorePlusException) {
      return error;
    }

    if (error is FirebaseException) {
      return FirestorePlusException(
        type: _mapCodeToType(error.code),
        message: error.message ?? 'A Firebase error occurred',
        code: error.code,
        originalException: error,
        stackTrace: stackTrace,
        operation: operation,
        path: path,
      );
    }

    if (error is TimeoutException) {
      return FirestorePlusException(
        type: FirestoreErrorType.timeout,
        message: 'The operation timed out.',
        originalException: error,
        stackTrace: stackTrace,
        operation: operation,
        path: path,
      );
    }

    return FirestorePlusException(
      type: FirestoreErrorType.unknown,
      message: error.toString(),
      originalException: error,
      stackTrace: stackTrace,
      operation: operation,
      path: path,
    );
  }

  static FirestoreErrorType _mapCodeToType(String code) {
    switch (code) {
      case 'permission-denied':
        return FirestoreErrorType.permissionDenied;
      case 'not-found':
        return FirestoreErrorType.notFound;
      case 'already-exists':
        return FirestoreErrorType.alreadyExists;
      case 'invalid-argument':
        return FirestoreErrorType.invalidArgument;
      case 'unavailable':
        return FirestoreErrorType.unavailable;
      case 'deadline-exceeded':
        return FirestoreErrorType.timeout;
      case 'cancelled':
        return FirestoreErrorType.cancelled;
      case 'resource-exhausted':
        return FirestoreErrorType.resourceExhausted;
      case 'network-request-failed':
        return FirestoreErrorType.network;
      default:
        return FirestoreErrorType.unknown;
    }
  }

  /// Determines if an error is considered transient and should be retried.
  static bool isRetryable(Object error) {
    if (error is TimeoutException) return true;

    if (error is FirestorePlusException) {
      return _isTypeRetryable(error.type);
    }

    if (error is FirebaseException) {
      return _isTypeRetryable(_mapCodeToType(error.code));
    }

    return false;
  }

  static bool _isTypeRetryable(FirestoreErrorType type) {
    switch (type) {
      case FirestoreErrorType.network:
      case FirestoreErrorType.unavailable:
      case FirestoreErrorType.timeout:
      case FirestoreErrorType.resourceExhausted:
        return true;
      case FirestoreErrorType.permissionDenied:
      case FirestoreErrorType.notFound:
      case FirestoreErrorType.invalidArgument:
      case FirestoreErrorType.alreadyExists:
      case FirestoreErrorType.cancelled:
      case FirestoreErrorType.serialization:
      case FirestoreErrorType.unknown:
        return false;
    }
  }
}
