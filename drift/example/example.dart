import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:sentry/sentry.dart';
import 'package:sentry_drift/sentry_drift.dart';

import 'database.dart';

Future<void> main() async {
  // ATTENTION: Change the DSN below with your own to see the events in Sentry. Get one at sentry.io
  const dsn =
      'https://b6a6002ada31addaced3c0cc208e3df6@o4509908127842304.ingest.us.sentry.io/4509908136558592';

  await Sentry.init(
    (options) {
      options.dsn = dsn;
      options.tracesSampleRate = 1.0;
      options.debug = true;
    },
    appRunner: runApp, // Init your App.
  );
}

Future<void> runApp() async {
  final tr = Sentry.startTransaction('drift', 'op', bindToScope: true);
  final executor = NativeDatabase.memory().interceptWith(
    SentryQueryInterceptor(databaseName: 'your_db_name'),
  );

  final db = AppDatabase(executor);

  await db.transaction(() async {
    await db.into(db.todoItems).insert(
          TodoItemsCompanion.insert(
            title: 'This is a test thing',
            content: 'test',
          ),
        );

    await db.transaction(() async {
      await db.into(db.todoItems).insert(
            TodoItemsCompanion.insert(
              title: 'This is a test thing in the tx',
              content: 'test',
            ),
          );
    });

    await db.batch((batch) {
      batch.insertAll(db.todoItems, [
        TodoItemsCompanion.insert(title: 'First entry', content: 'My content'),
        TodoItemsCompanion.insert(
          title: 'Another entry',
          content: 'More content',
        ),
      ]);
    });
  });

  await db.batch((batch) async {
    batch.insertAll(db.todoItems, [
      TodoItemsCompanion.insert(title: 'This is a test', content: 'test'),
    ]);
  });

  final items = await db.select(db.todoItems).get();
  print(items);

  await db.close();

  await tr.finish(status: const SpanStatus.ok());
}
