import 'dart:convert';

import 'client_reports/client_report.dart';
import 'metrics/metric.dart';
import 'protocol.dart';
import 'sentry_attachment/sentry_attachment.dart';
import 'sentry_envelope_header.dart';
import 'sentry_envelope_item.dart';
import 'sentry_item_type.dart';
import 'sentry_options.dart';
import 'sentry_trace_context_header.dart';
import 'sentry_user_feedback.dart';
import 'utils.dart';

/// Class representation of `Envelope` file.
class SentryEnvelope {
  SentryEnvelope(this.header, this.items,
      {this.containsUnhandledException = false});

  /// Header describing envelope content.
  final SentryEnvelopeHeader header;

  /// All items contained in the envelope.
  final List<SentryEnvelopeItem> items;

  /// Whether the envelope contains an unhandled exception.
  /// This is used to determine if the native SDK should start a new session.
  final bool containsUnhandledException;

  /// Create a [SentryEnvelope] containing one [SentryEnvelopeItem] which holds the [SentryEvent] data.
  factory SentryEnvelope.fromEvent(
    SentryEvent event,
    SdkVersion sdkVersion, {
    String? dsn,
    SentryTraceContextHeader? traceContext,
    List<SentryAttachment>? attachments,
  }) {
    bool containsUnhandledException = false;

    if (event.exceptions != null && event.exceptions!.isNotEmpty) {
      // Check all exceptions for any unhandled ones
      containsUnhandledException = event.exceptions!.any((exception) {
        return exception.mechanism?.handled == false;
      });
    }

    return SentryEnvelope(
      SentryEnvelopeHeader(
        event.eventId,
        sdkVersion,
        dsn: dsn,
        traceContext: traceContext,
      ),
      [
        SentryEnvelopeItem.fromEvent(event),
        if (attachments != null)
          ...attachments.map((e) => SentryEnvelopeItem.fromAttachment(e))
      ],
      containsUnhandledException: containsUnhandledException,
    );
  }

  @Deprecated('Will be removed in a future version.')
  factory SentryEnvelope.fromUserFeedback(
    SentryUserFeedback feedback,
    SdkVersion sdkVersion, {
    String? dsn,
  }) {
    return SentryEnvelope(
      // no need for [traceContext]
      SentryEnvelopeHeader(
        feedback.eventId,
        sdkVersion,
        dsn: dsn,
      ),
      [SentryEnvelopeItem.fromUserFeedback(feedback)],
    );
  }

  /// Create a [SentryEnvelope] containing one [SentryEnvelopeItem] which holds the [SentryTransaction] data.
  factory SentryEnvelope.fromTransaction(
    SentryTransaction transaction,
    SdkVersion sdkVersion, {
    String? dsn,
    SentryTraceContextHeader? traceContext,
    List<SentryAttachment>? attachments,
  }) {
    return SentryEnvelope(
      SentryEnvelopeHeader(
        transaction.eventId,
        sdkVersion,
        dsn: dsn,
        traceContext: traceContext,
      ),
      [
        SentryEnvelopeItem.fromTransaction(transaction),
        if (attachments != null)
          ...attachments.map((e) => SentryEnvelopeItem.fromAttachment(e))
      ],
    );
  }

  /// Create a [SentryEnvelope] containing one [SentryEnvelopeItem] which holds the [Metric] data.
  factory SentryEnvelope.fromMetrics(
    Map<int, Iterable<Metric>> metricsBuckets,
    SdkVersion sdkVersion, {
    String? dsn,
  }) {
    return SentryEnvelope(
      SentryEnvelopeHeader(
        SentryId.newId(),
        sdkVersion,
        dsn: dsn,
      ),
      [SentryEnvelopeItem.fromMetrics(metricsBuckets)],
    );
  }

  /// Stream binary data representation of `Envelope` file encoded.
  Stream<List<int>> envelopeStream(SentryOptions options) async* {
    yield utf8JsonEncoder.convert(header.toJson());

    final newLineData = utf8.encode('\n');
    for (final item in items) {
      try {
        final dataFuture = item.dataFactory();
        final data = dataFuture is Future ? await dataFuture : dataFuture;

        // Only attachments should be filtered according to
        // SentryOptions.maxAttachmentSize
        if (item.header.type == SentryItemType.attachment &&
            data.length > options.maxAttachmentSize) {
          continue;
        }

        yield newLineData;
        yield utf8JsonEncoder.convert(await item.header.toJson(data.length));
        yield newLineData;
        yield data;
      } catch (e, st) {
        // ignore: avoid_print
        print('[Envelope] item serialization failed type=${item.header.type} err=$e');
        // 在 OHOS 上为保证 envelope 完整，不丢弃 item：
        // 尝试以回退方式序列化原始对象（toJson -> jsonEncode -> utf8），失败则跳过。
        try {
          final original = item.originalObject;
          if (original != null) {
            // 优先调用对象的 toJson()，避免 jsonEncode 直接失败
            List<int>? data;
            try {
              final dyn = original as dynamic;
              final map = dyn.toJson != null ? dyn.toJson() as Map<String, dynamic> : null;
              if (map != null) {
                data = utf8JsonEncoder.convert(map);
              }
            } catch (_) {}
            data ??= utf8.encode(jsonEncode(original));
            // ignore: avoid_print
            print('[Envelope] fallback ok type=${item.header.type} dataLen=${data.length}');
            yield newLineData;
            yield utf8JsonEncoder.convert(await item.header.toJson(data.length));
            yield newLineData;
            yield data;
            continue;
          }
        } catch (e2, st2) {
          // ignore: avoid_print
          print('[Envelope] fallback failed type=${item.header.type} err=$e2');
          if (options.automatedTestMode) rethrow;
        }
        if (options.automatedTestMode) rethrow;
        continue;
      }
    }
  }

  /// Add an envelope item containing client report data.
  void addClientReport(ClientReport? clientReport) {
    if (clientReport != null) {
      final envelopeItem = SentryEnvelopeItem.fromClientReport(clientReport);
      items.add(envelopeItem);
    }
  }
}
