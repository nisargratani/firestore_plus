# firestore_plus example

A runnable app that exercises every major `firestore_plus` feature: typed CRUD,
queries (including `Filter.or`), cache policies, invalidation, error mapping,
retry and timeouts, pagination, streams, batches, transactions, logging and
metrics.

## Run it against the Firestore emulator (no Firebase project needed)

```bash
# in one terminal (requires the Firebase CLI and Java 21+)
firebase emulators:start --only firestore --project demo-firestore-plus

# in another terminal
cd example
flutter run            # pick macOS, Android, iOS or Chrome
```

Tap **Run feature demo** and follow the log on screen.

## Run it against your own Firebase project

1. Run `flutterfire configure` in this folder.
2. In `lib/main.dart`, pass `DefaultFirebaseOptions.currentPlatform` to
   `Firebase.initializeApp` and set `useEmulator = false`.

The demo writes to the `users` collection and cleans up after itself.
