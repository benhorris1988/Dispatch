import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Push registration plumbing (MOB-04).
///
/// The app never talks to APNs or FCM itself; it obtains a device token from the platform's
/// push SDK, hands it to `devices.php register`, and the server sends through whichever
/// provider is configured. This interface is the seam: [NoopPushService] is what this build
/// ships, because a Firebase project (google-services.json / GoogleService-Info.plist) is a
/// real credential and faking one would only produce a build that cannot receive anything.
///
/// A real implementation (see mobile/README.md, "Enabling push") wraps firebase_messaging:
/// `getToken()` → [token], `onMessageOpenedApp` / `getInitialMessage()` → [init]'s `onLink`
/// with the message's `data['link']`, and `onTokenRefresh` → [DeviceRegistrar.register].
abstract class PushService {
  /// The implementation for this build. Replaced at start-up when a real sender exists.
  static PushService instance = const NoopPushService();

  /// True when this build can obtain a push token at all.
  bool get configured;

  /// `ios` | `android` | `web`, as devices.php expects.
  String get platform;

  /// Shown to the user in their device list; no personal data.
  String get deviceLabel;

  /// Start listening. [onLink] receives the `link` of a tapped notification
  /// (an app path such as `/items/WI-1042`, or a `dispatch://` URL).
  Future<void> init({required void Function(String link) onLink});

  /// The current registration token, or null when there is none.
  Future<String?> token();
}

/// What ships without a Firebase project: no token, so nothing to register.
class NoopPushService implements PushService {
  const NoopPushService();

  @override
  bool get configured => false;

  @override
  String get platform => platformName();

  @override
  String get deviceLabel => platformLabel();

  @override
  Future<void> init({required void Function(String link) onLink}) async {}

  @override
  Future<String?> token() async => null;

  static String platformName() {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'ios',
      TargetPlatform.android => 'android',
      _ => 'web',
    };
  }

  static String platformLabel() {
    if (kIsWeb) return 'Web browser';
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'iPhone or iPad',
      TargetPlatform.android => 'Android device',
      TargetPlatform.macOS => 'Mac',
      TargetPlatform.windows => 'Windows PC',
      TargetPlatform.linux => 'Linux PC',
      _ => 'Device',
    };
  }
}

/// Keeps the server's `device_tokens` in step with the session: register after sign-in,
/// unregister before sign-out. Failures are logged, never surfaced — a push registration
/// must not get in the way of using the app.
class DeviceRegistrar {
  static const _tokenKey = 'dispatch.push.token';

  Future<bool> register() async {
    final push = PushService.instance;
    final t = await push.token();
    if (t == null || t.isEmpty) return false;
    try {
      await Api.post('devices.php', 'register', {'platform': push.platform, 'token': t, 'device_label': push.deviceLabel});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, t);
      return true;
    } catch (e) {
      debugPrint('[push] device registration failed: $e');
      return false;
    }
  }

  Future<void> unregister() async {
    final prefs = await SharedPreferences.getInstance();
    final t = prefs.getString(_tokenKey);
    if (t == null || t.isEmpty) return;
    try {
      await Api.post('devices.php', 'unregister', {'token': t});
    } catch (e) {
      debugPrint('[push] device unregistration failed: $e');
    } finally {
      await prefs.remove(_tokenKey);
    }
  }
}
