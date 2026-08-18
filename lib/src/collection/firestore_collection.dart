import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/firestore_operation_options.dart';
import '../core/firestore_plus.dart';
import 'firestore_document.dart';
import 'firestore_query.dart';

/// A typed reference to a Firestore collection.
class FirestoreCollection<T> {
  /// The native Firestore collection reference.
  final CollectionReference nativeRef;

  /// The [FirestorePlus] instance.
  final FirestorePlus firestore;

  /// The serialization mapper.
  final T Function(Map<String, dynamic> data, String id) fromFirestore;

  /// The deserialization mapper.
  final Map<String, dynamic> Function(T instance) toFirestore;

  FirestoreCollection(
    this.nativeRef,
    this.firestore,
    this.fromFirestore,
    this.toFirestore,
  );

  /// The ID of the collection.
  String get id => nativeRef.id;

  /// The path of the collection.
  String get path => nativeRef.path;

  /// Returns a [FirestoreDocument] for the given [id].
  /// If [id] is omitted, an auto-generated ID is used.
  FirestoreDocument<T> doc([String? id]) {
    return FirestoreDocument<T>(
      id == null ? nativeRef.doc() : nativeRef.doc(id),
      firestore,
      fromFirestore,
      toFirestore,
    );
  }

  /// Adds a new document with the given [data], returning a reference to it.
  Future<FirestoreDocument<T>> add(T data,
      {FirestoreOperationOptions? options}) async {
    final ref = nativeRef.doc();
    final docRef = doc(ref.id);
    await docRef.set(data, options: options);
    return docRef;
  }

  /// Helper to get a single document by [id].
  Future<T?> getById(String id, {FirestoreOperationOptions? options}) {
    return doc(id).get(options: options);
  }

  /// Helper to check if a document with [id] exists.
  Future<bool> exists(String id, {FirestoreOperationOptions? options}) {
    return doc(id).exists(options: options);
  }

  /// Helper to delete a document by [id].
  Future<void> delete(String id, {FirestoreOperationOptions? options}) {
    return doc(id).delete(options: options);
  }

  /// Returns a new [FirestoreQuery] starting from this collection.
  FirestoreQuery<T> query() {
    return FirestoreQuery<T>(
      nativeQuery: nativeRef,
      firestore: firestore,
      fromFirestore: fromFirestore,
      collectionPath: path,
    );
  }

  /// Executes the query and returns the results.
  Future<List<T>> get({FirestoreOperationOptions? options}) {
    return query().get(options: options);
  }
}
