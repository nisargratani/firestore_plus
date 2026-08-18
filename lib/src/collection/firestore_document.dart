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
      throw ErrorMapper.map(
        FirestorePlusException(
          type: FirestoreErrorType.serialization,
          message: 'Failed to deserialize document: $e',
          originalException: e,
          stackTrace: st,
          operation: 'GET $path',
          path: path,
        ),
      );
    }
  }

  /// Sets the document [data], optionally applying [options].
  Future<void> set(T data,
      {SetOptions? setOptions, FirestoreOperationOptions? options}) async {
    await firestore.executor.executeWrite(
      path: path,
      type: FirestoreOperationType.set,
      options: options,
      operation: () async {
        final serialized = toFirestore(data);
        await nativeRef.set(serialized, setOptions);
        // Invalidate cache after write
        await firestore.cache.invalidate(path);
      },
    );
  }

  /// Updates the document with the given [data], optionally applying [options].
  Future<void> update(Map<String, dynamic> data,
      {FirestoreOperationOptions? options}) async {
    await firestore.executor.executeWrite(
      path: path,
      type: FirestoreOperationType.update,
      options: options,
      operation: () async {
        await nativeRef.update(data);
        // Invalidate cache after write
        await firestore.cache.invalidate(path);
      },
    );
  }

  /// Deletes the document, optionally applying [options].
  Future<void> delete({FirestoreOperationOptions? options}) async {
    await firestore.executor.executeWrite(
      path: path,
      type: FirestoreOperationType.delete,
      options: options,
      operation: () async {
        await nativeRef.delete();
        // Invalidate cache after write
        await firestore.cache.invalidate(path);
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
  Stream<T?> snapshots() {
    return nativeRef.snapshots().map((snap) {
      if (!snap.exists || snap.data() == null) return null;
      try {
        return fromFirestore(snap.data() as Map<String, dynamic>, snap.id);
      } catch (e, st) {
        firestore.config.logger.error(
            'Failed to deserialize stream document: $e',
            error: e,
            stackTrace: st);
        // Depending on design we might yield null or throw an error to the stream.
        // Rethrowing allows stream listeners to handle the error properly.
        throw ErrorMapper.map(
          FirestorePlusException(
            type: FirestoreErrorType.serialization,
            message: 'Failed to deserialize document stream: $e',
            originalException: e,
            stackTrace: st,
            operation: 'STREAM GET $path',
            path: path,
          ),
        );
      }
    });
  }
}
