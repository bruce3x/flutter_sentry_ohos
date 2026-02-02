import 'dart:io' show Platform;

bool get platformIsOhos {
  try {
    return Platform.operatingSystem.toLowerCase() == 'ohos';
  } catch (_) {
    return false;
  }
}
