import 'package:cloud_firestore/cloud_firestore.dart';

import '../collection/firestore_document.dart';
import '../core/firestore_plus.dart';
import '../error/error_mapper.dart';
import '../error/firestore_plus_exception.dart';

/// A typed wrapper for a Firestore WriteBatch.
///
/// Batches use native Firestore semantics: no application-level retry or
/// timeout is applied to [commit].
class FirestoreBatch {
  /// The native WriteBatch.
  final WriteBatch nativeBatch;

  /// The [FirestorePlus] instance.
  final FirestorePlus firestore;

  /// The paths that will be invalidated in cache after a successful commit.
  final Set<String> _pathsToInvalidate = {};

  /// Wraps [nativeBatch]. Usually obtained from [FirestorePlus.batch].
  FirestoreBatch(this.nativeBatch, this.firestore);

  /// Writes to the document referred to by [doc]. If the document does not exist yet, it will be created.
  ///
  /// Throws a [FirestorePlusException] of type
  /// [FirestoreErrorType.serialization] if `toFirestore` fails.
  void set<T>(FirestoreDocument<T> doc, T data, [SetOptions? options]) {
    final serialized = doc.serialize(data, 'BATCH SET ${doc.path}');
    nativeBatch.set(doc.nativeRef, serialized, options);
    _pathsToInvalidate.add(doc.path);
  }

  /// Updates fields in the document referred to by [doc].
  void update<T>(FirestoreDocument<T> doc, Map<String, dynamic> data) {
    nativeBatch.update(doc.nativeRef, data);
    _pathsToInvalidate.add(doc.path);
  }

  /// Deletes the document referred to by [doc].
  void delete<T>(FirestoreDocument<T> doc) {
    nativeBatch.delete(doc.nativeRef);
    _pathsToInvalidate.add(doc.path);
  }

  /// Commits all of the writes in this write batch as a single atomic unit.
  ///
  /// Failures are thrown as [FirestorePlusException] carrying the real error
  /// type (e.g. `permissionDenied`, `notFound`).
  Future<void> commit() async {
    try {
      await nativeBatch.commit();
    } catch (e, st) {
      throw ErrorMapper.map(e, st, 'BATCH COMMIT');
    }
    // Invalidate the affected documents and their collections' queries.
    for (final path in _pathsToInvalidate) {
      await firestore.cache.invalidateDocument(path);
    }
  }
}
