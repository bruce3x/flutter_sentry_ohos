import 'package:sentry/sentry.dart';
import '../sentry_flutter.dart';

/// Ensures OHOS-specific contexts override any Android defaults produced by Dart IO enrichers.
class OhosOverrideEventProcessor implements EventProcessor {
  const OhosOverrideEventProcessor();

  @override
  Future<SentryEvent?> apply(SentryEvent event, Hint hint) async {
    // 仅在运行时确认是 OHOS 绑定时强制覆盖（不依赖 dart:io 平台字符串）
    if (SentryFlutter.ohosRuntime != true) {
      return event;
    }

    final ctx = event.contexts;
    final os = ctx.operatingSystem ?? SentryOperatingSystem();
    // Enforce OpenHarmony naming; keep existing version/build if present
    os.name = os.name ?? 'OpenHarmony';
    if (os.name != 'OpenHarmony') {
      os.name = 'OpenHarmony';
    }
    ctx.operatingSystem = os;

    // Optional: sanitize misleading tags if present
    final tags = event.tags ?? <String, String>{};
    if (tags['os.name'] == 'Android') {
      tags['os.name'] = 'OpenHarmony';
    }

    // Enhancement: 标记 try/catch 捕获的异常为 handled=true（约定：当 tag 'handled' 为 true/yes/1 时）
    try {
      final handledTag = tags['handled'];
      final shouldMarkHandled = handledTag == 'true' || handledTag == 'yes' || handledTag == '1';
      if (shouldMarkHandled && event.exceptions != null && event.exceptions!.isNotEmpty) {
        final updated = <SentryException>[];
        for (final ex in event.exceptions!) {
          if (ex.mechanism != null) {
            ex.mechanism!.handled = true;
            updated.add(ex);
          } else {
            final mech = Mechanism(type: 'generic', handled: true);
            updated.add(ex.copyWith(mechanism: mech));
          }
        }
        event = event.copyWith(exceptions: updated);
        // 确保 tags['handled'] 与 mechanism.handled 对齐
        tags['handled'] = 'yes';
      }
    } catch (_) {}

    // 可选：推断主线程状态，补充 tags['thread.state']
    try {
      final threads = event.threads;
      if (threads != null && threads.isNotEmpty) {
        final main = threads.firstWhere(
          (t) => t.current == true,
          orElse: () => threads.first,
        );
        final st = main.name; // 使用线程名作为可读状态占位
        if (st != null && st.isNotEmpty) {
          tags['thread.name'] = st;
        }
      }
    } catch (_) {}

    event.tags = tags;

    event.contexts = ctx;
    return event;
  }
}


