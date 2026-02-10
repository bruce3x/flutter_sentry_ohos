// backcompatibility for Flutter < 3.3
// ignore: unnecessary_import
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../sentry_flutter.dart';
import 'native/sentry_native_binding.dart';

class FileSystemTransport implements Transport {
  FileSystemTransport(this._native, this._options);

  final SentryNativeBinding _native;
  final SentryFlutterOptions _options;

  @override
  Future<SentryId?> send(SentryEnvelope envelope) async {
    // 打印 envelope JSON 数据
    try {
      final envelopeJson = <String, dynamic>{
        'header': <String, dynamic>{
          'eventId': envelope.header.eventId?.toString(),
          'sdk': envelope.header.sdkVersion?.toJson(),
          'dsn': envelope.header.dsn,
          'sentAt': envelope.header.sentAt?.toIso8601String(),
          'traceContext': envelope.header.traceContext?.toJson(),
        },
        'items': <Map<String, dynamic>>[],
        'containsUnhandledException': envelope.containsUnhandledException,
      };

      // 处理每个 item
      for (final item in envelope.items) {
        final itemJson = <String, dynamic>{
          'header': <String, dynamic>{
            'type': item.header.type.toString(),
            // 'length': item.header.length,
            'contentType': item.header.contentType,
            'fileName': item.header.fileName,
            'attachmentType': item.header.attachmentType,
          },
        };

        // 尝试读取 item 数据（如果是文本类型，尝试解析为 JSON）
        try {
          final itemData = await item.dataFactory();
          final itemDataBytes = Uint8List.fromList(itemData);

          // 如果是 event/transaction 类型，尝试解析为 JSON
          if (item.header.type.toString().contains('event') ||
              item.header.type.toString().contains('transaction')) {
            try {
              final itemDataString = utf8.decode(itemDataBytes);
              final itemDataJson = jsonDecode(itemDataString);
              itemJson['data'] = itemDataJson;
            } catch (_) {
              // 如果解析失败，只显示数据长度
              itemJson['data'] = <String, dynamic>{
                'length': itemDataBytes.length,
                'preview': itemDataBytes.length > 0
                    ? utf8.decode(itemDataBytes.take(200).toList(), allowMalformed: true)
                    : null,
              };
            }
          } else {
            // 其他类型只显示长度
            itemJson['data'] = <String, dynamic>{
              'length': itemDataBytes.length,
            };
          }
        } catch (_) {
          itemJson['data'] = 'Failed to read item data';
        }

        (envelopeJson['items'] as List).add(itemJson);
      }

      final jsonString = const JsonEncoder.withIndent('  ').convert(envelopeJson);
      print('Envelope JSON: $envelopeJson');
      _options.logger(
        SentryLevel.debug,
        'Envelope JSON:\n$jsonString',
      );

      // 将 JSON 字符串写入日志文件
      try {
        final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
        final eventId = envelope.header.eventId?.toString() ?? 'unknown';
        final logDir = Directory.systemTemp;
        final logFile = File('${logDir.path}/sentry_envelope_${eventId}_$timestamp.json');
        await logFile.writeAsString(jsonString, flush: true);
        print('Envelope logFile: ${logFile.path}');
        _options.logger(
          SentryLevel.debug,
          'Envelope JSON written to: ${logFile.path}',
        );
      } catch (fileError) {
        print('Envelope fileError: $fileError');
        _options.logger(
          SentryLevel.warning,
          'Failed to write envelope JSON to file: $fileError',
        );
      }
    } catch (e) {
      print('Envelope eeee: $e');
      _options.logger(
        SentryLevel.warning,
        'Failed to serialize envelope to JSON: $e',
      );
    }

    final envelopeData = <int>[];
    await envelope.envelopeStream(_options).forEach(envelopeData.addAll);
    try {
      // TODO avoid copy
      await _native.captureEnvelope(Uint8List.fromList(envelopeData),
          envelope.containsUnhandledException);
    } catch (exception, stackTrace) {
      _options.logger(
        SentryLevel.error,
        'Failed to save envelope',
        exception: exception,
        stackTrace: stackTrace,
      );
      if (_options.automatedTestMode) {
        rethrow;
      }
      return SentryId.empty();
    }

    return envelope.header.eventId;
  }
}
