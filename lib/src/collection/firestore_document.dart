import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/firestore_operation_options.dart';
import '../core/firestore_plus.dart';
import '../error/error_mapper.dart';
import '../error/firestore_plus_exception.dart';
import '../metrics/firestore_metrics.dart';

/// A typed reference to a Firestore document.
class FirestoreDocument<T> {
  /// The native Firestore document reference.
  final DocumentReference nativeRef;

  /// The [FirestorePlus] instance.
  final FirestorePlus firestore;

  /// The serialization mapper.
  final T Function(Map<String, dynamic> data, String id) fromFirestore;

  /// The deserialization mapper.
  final Map<String, dynamic> Function(T instance) toFirestore;

  FirestoreDocument(
    this.nativeRef,
    this.firestore,
    this.fromFirestore,
    this.toFirestore,
  );

  /// The ID of the document.
  String get id => nativeRef.id;

  /// The path of the document.
  String get path => nativeRef.path;

  /// Gets the document, optionally applying [options].
  ///
  /// Returns `null` when the document does not exist.
  Future<T?> get({FirestoreOperationOptions? options}) async {
    final data = await firestore.executor.executeRead(
      path: path,
      cacheKey: path,
      options: options,
      fetchFromNetwork: () async {
        final snap = await nativeRef.get();
        if (!snap.exists || snap.data() == null) return null;
        return snap.data() as Map<String, dynamic>;
      },
    );

    if (data == null) return null;

    try {
      return fromFirestore(data, id);
    } catch (e, st) {
      throw FirestorePlusException(
        type: FirestoreErrorType.serialization,
        message: 'Failed to deserialize document: $e',
        originalException: e,
        stackTrace: st,
        operation: 'GET $path',
        path: path,
      );
    }
  }

  /// Sets the document [data], optionally applying [options].
  Future<void> set(T data,
      {SetOptions? setOptions, FirestoreOperationOptions? options}) async {
    final Map<String, dynamic> serialized;
    try {
      serialized = toFirestore(data);
    } catch (e, st) {
      throw FirestorePlusException(
        type: FirestoreErrorType.serialization,
        message: 'Failed to serialize document: $e',
        originalException: e,
        stackTrace: st,
        operation: 'SET $path',
        path: path,
      );
    }
    await firestore.executor.executeWrite(
      path: path,
      type: FirestoreOperationType.set,
      options: options,
      retryOnTimeout: false,
      operation: () async {
        await nativeRef.set(serialized, setOptions);
        await firestore.cache.invalidateDocument(path);
      },
    );
  }

  /// Updates the document with the given [data], optionally applying [options].
  ///
  /// Throws a [FirestorePlusException] of type [FirestoreErrorType.notFound]
  /// if the document does not exist.
  Future<void> update(Map<String, dynamic> data,
      {FirestoreOperationOptions? options}) async {
    await firestore.executor.executeWrite(
      path: path,
      type: FirestoreOperationType.update,
      options: options,
      retryOnTimeout: false,
      operation: () async {
        await nativeRef.update(data);
        await firestore.cache.invalidateDocument(path);
      },
    );
  }

  /// Deletes the document, optionally applying [options].
  Future<void> delete({FirestoreOperationOptions? options}) async {
    await firestore.executor.executeWrite(
      path: path,
      type: FirestoreOperationType.delete,
      options: options,
      retryOnTimeout: false,
      operation: () async {
        await nativeRef.delete();
        await firestore.cache.invalidateDocument(path);
      },
    );
  }

  /// Returns whether the document exists, optionally applying [options].
  ///
  /// This operation is not cached by default, but respects timeout/retry.
  Future<bool> exists({FirestoreOperationOptions? options}) async {
    bool doesExist = false;
    await firestore.executor.executeWrite(
      // Reusing executeWrite because we don't cache 'exists' bool natively.
      path: path,
      type: FirestoreOperationType.exists,
      options: options,
      operation: () async {
        final snap = await nativeRef.get();
        doesExist = snap.exists;
      },
    );
    return doesExist;
  }

  /// A typed stream of document snapshots.
  ///
  /// Emits `null` while the document does not exist. Errors (including
  /// deserialization failures) are emitted as [FirestorePlusException].
  Stream<T?> snapshots() {
    final operation = 'STREAM GET $path';
    return nativeRef.snapshots().map((snap) {
      if (!snap.exists || snap.data() == null) return null;
      try {
        return fromFirestore(snap.data() as Map<String, dynamic>, snap.id);
      } catch (e, st) {
        firestore.config.logger.error(
            'Failed to deserialize stream document: $e',
            error: e,
            stackTrace: st);
        throw FirestorePlusException(
          type: FirestoreErrorType.serialization,
          message: 'Failed to deserialize document stream: $e',
          originalException: e,
          stackTrace: st,
          operation: operation,
          path: path,
        );
      }
    }).transform(
        StreamTransformer<T?, T?>.fromHandlers(handleError: (e, st, sink) {
      sink.addError(ErrorMapper.map(e, st, operation, path), st);
    }));
  }
}
