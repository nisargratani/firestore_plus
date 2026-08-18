import 'package:cloud_firestore/cloud_firestore.dart';

import '../collection/firestore_document.dart';
import '../core/firestore_plus.dart';
import '../error/error_mapper.dart';
import '../error/firestore_plus_exception.dart';

/// A typed wrapper for a Firestore Transaction.
class FirestoreTransaction {
  /// The native Transaction.
  final Transaction nativeTransaction;

  /// The [FirestorePlus] instance.
  final FirestorePlus firestore;

  FirestoreTransaction(this.nativeTransaction, this.firestore);

  /// Reads the document referred to by [doc].
  Future<T?> get<T>(FirestoreDocument<T> doc) async {
    try {
      final snap = await nativeTransaction.get(doc.nativeRef);
      if (!snap.exists || snap.data() == null) return null;
      return doc.fromFirestore(snap.data() as Map<String, dynamic>, snap.id);
    } catch (e, st) {
      throw ErrorMapper.map(
        FirestorePlusException(
          type: FirestoreErrorType.unknown,
          message: 'Transaction read failed for ${doc.path}: $e',
          originalException: e,
          stackTrace: st,
          operation: 'TRANSACTION GET ${doc.path}',
          path: doc.path,
        ),
      );
    }
  }

  /// Writes to the document referred to by [doc].
  void set<T>(FirestoreDocument<T> doc, T data, [SetOptions? options]) {
    final serialized = doc.toFirestore(data);
    nativeTransaction.set(doc.nativeRef, serialized, options);
  }

  /// Updates fields in the document referred to by [doc].
  void update<T>(FirestoreDocument<T> doc, Map<String, dynamic> data) {
    nativeTransaction.update(doc.nativeRef, data);
  }

  /// Deletes the document referred to by [doc].
  void delete<T>(FirestoreDocument<T> doc) {
    nativeTransaction.delete(doc.nativeRef);
  }
}
