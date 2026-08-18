import 'package:cloud_firestore/cloud_firestore.dart';

/// Represents a cursor for pagination in Firestore.
class PaginationCursor {
  /// The document snapshot representing the cursor position.
  final DocumentSnapshot document;

  const PaginationCursor(this.document);
}

/// Represents a paginated result set.
class PaginatedResult<T> {
  /// The list of items in the current page.
  final List<T> items;

  /// Whether there are more items to fetch.
  final bool hasMore;

  /// The cursor to use for fetching the next page.
  final PaginationCursor? cursor;

  const PaginatedResult({
    required this.items,
    required this.hasMore,
    this.cursor,
  });
}
