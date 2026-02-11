// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
// SentryId : 035b48b846db479cb9d2800cc714fce8
import 'dart:async';

import 'package:sentry/sentry.dart';

import 'event_example.dart';

/// Sends a test exception report to Sentry.io using this Dart client.
Future<void> main() async {
  // ATTENTION: Change the DSN below with your own to see the events in Sentry. Get one at sentry.io
  const dsn =
      'https://b6a6002ada31addaced3c0cc208e3df6@o4509908127842304.ingest.us.sentry.io/4509908136558592';

  await Sentry.init(
    (options) => options
      ..dsn = dsn
      ..debug = true
      ..sendDefaultPii = true
      ..addEventProcessor(TagEventProcessor()),
    appRunner: runApp,
  );
}

Future<void> runApp() async {
  print('\nReporting a complete event example: ');

  Sentry.addBreadcrumb(
    Breadcrumb(
      message: 'Authenticated user',
      category: 'auth',
      type: 'debug',
      data: {
        'admin': true,
        'permissions': [1, 2, 3]
      },
    ),
  );

  await Sentry.configureScope((scope) async {
    await scope.setUser(SentryUser(
      id: '800',
      username: 'first-user',
      email: 'first@user.lan',
      // ipAddress: '127.0.0.1', sendDefaultPii feature is enabled
      // ignore: deprecated_member_use
      extras: <String, String>{'first-sign-in': '2020-01-01'},
    ));
    scope
      // ..fingerprint = ['example-dart'], fingerprint forces events to group together
      ..transaction = '/example/app'
      ..level = SentryLevel.warning;
    await scope.setTag('build', '579');
    await scope.setExtra('company-name', 'Dart Inc');
  });

  // Sends a full Sentry event payload to show the different parts of the UI.
  final sentryId = await Sentry.captureEvent(event);

  print('Capture event result : SentryId : $sentryId');

  print('\nCapture message: ');

  // Sends a full Sentry event payload to show the different parts of the UI.
  final messageSentryId = await Sentry.captureMessage(
    'Message 1',
    level: SentryLevel.warning,
    template: 'Message %s',
    params: ['1'],
  );

  print('Capture message result : SentryId : $messageSentryId');

  try {
    await loadConfig();
  } catch (error, stackTrace) {
    print('\nReporting the following stack trace: ');
    print(stackTrace);
    final sentryId = await Sentry.captureException(
      error,
      stackTrace: stackTrace,
    );

    print('Capture exception result : SentryId : $sentryId');
  }

  // capture unhandled error
  await loadConfig();
}

Future<void> loadConfig() async {
  await parseConfig();
}

Future<void> parseConfig() async {
  await decode();
}

Future<void> decode() async {
  throw StateError('This is a test error');
}

class TagEventProcessor implements EventProcessor {
  @override
  SentryEvent? apply(SentryEvent event, hint) {
    return event..tags?.addAll({'page-locale': 'en-us'});
  }
}
