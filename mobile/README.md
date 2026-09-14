# Dispatch — Flutter client

One codebase for the web app and the native Android and iOS apps (MOB-01). Package
`dispatch_app`; application id / bundle id `uk.co.dispatch.app`; display name **Dispatch**.
What screens can rely on is in `../docs/CLIENT.md`; the API contract is `../docs/API.md`.

Flutter SDK on this box: `"C:\temp\flutter sdk\flutter\bin\flutter.bat"`. `analyze`, `pub` and
`test` work from Git Bash; run `build` from **PowerShell** — the space in the SDK path breaks the
bash invocation.

## Platforms

| Platform | Minimum | Project | State on this machine |
|---|---|---|---|
| Web | evergreen browsers | `web/` | built and served by `run_local.ps1` |
| Android | **Android 11 (API 30)** — `android/app/build.gradle.kts` `minSdk = 30` | `android/` | **release APK builds** (Android SDK 36.1.0, JDK 21 from Android Studio) |
| iOS | **iOS 16** — `IPHONEOS_DEPLOYMENT_TARGET = 16.0` | `ios/` | project generated and configured; **not built here** (no macOS / Xcode) |

The launcher icon on both platforms is the design's orange route mark
(`lib/widgets/dispatch_logo.dart`), rendered to PNG at every required size — legacy mipmaps and an
adaptive icon on Android, the full `AppIcon.appiconset` on iOS.

## Pointing the app at an API

The API base is a compile-time define; there is no in-app setting.

```
--dart-define=API_BASE=http://<host>:8090/api
```

| Where the app runs | API_BASE | Why |
|---|---|---|
| Web on this machine | `http://localhost:8090/api` (the default) | same origin as `run_local.ps1` |
| Android emulator | `http://10.0.2.2:8090/api` | `10.0.2.2` is the emulator's alias for the host's loopback, so the server bound to `localhost` is reachable |
| iOS simulator (on a Mac) | `http://localhost:8090/api` | the simulator shares the Mac's network stack |
| A physical phone | `http://<your LAN IP>:8090/api` | the phone cannot see `localhost`; the server must listen on all interfaces |

`run_local.ps1` binds `localhost` only. For a physical device, serve on all interfaces instead:

```powershell
C:\xampp\php\php.exe -S 0.0.0.0:8090 -t C:\xampp\htdocs\dispatch C:\xampp\htdocs\dispatch\router.php
```

and open port 8090 in Windows Firewall for the private network.

**Plain http is blocked by Android unless allow-listed.** Android 9+ refuses cleartext by
default and Flutter's `dart:io` honours that, so
`android/app/src/main/res/xml/network_security_config.xml` permits http to `10.0.2.2`,
`localhost` and `127.0.0.1` only. For a physical phone during development add your LAN address
to that file and rebuild; a real deployment uses https and needs nothing added.

## Android

### Run on the emulator

```powershell
& "C:\temp\flutter sdk\flutter\bin\flutter.bat" emulators                      # list AVDs
& "C:\temp\flutter sdk\flutter\bin\flutter.bat" emulators --launch <avd id>     # or create one in Android Studio (API 30+)
& "C:\temp\flutter sdk\flutter\bin\flutter.bat" run --dart-define=API_BASE=http://10.0.2.2:8090/api
```

The API (`run_local.ps1`) must be up and the demo seeded (`php seed_demo.php`).

### Build a release APK

```powershell
cd C:\xampp\htdocs\dispatch\mobile
& "C:\temp\flutter sdk\flutter\bin\flutter.bat" build apk --release --dart-define=API_BASE=http://10.0.2.2:8090/api
# → build\app\outputs\flutter-apk\app-release.apk   (~57 MB: one APK for every ABI)
& "C:\temp\flutter sdk\flutter\bin\flutter.bat" build apk --release --split-per-abi --dart-define=API_BASE=...
# → app-arm64-v8a-release.apk etc., roughly a third of the size each
& "C:\temp\flutter sdk\flutter\bin\flutter.bat" build appbundle --release --dart-define=API_BASE=...   # for Play / Intune
```

Install on the running emulator or a USB device: `adb install -r build\app\outputs\flutter-apk\app-release.apk`.

The release build is **signed with the debug keystore** (`build.gradle.kts` says so in a `TODO`),
which is right for installing on your own devices and wrong for a store or Intune. Signing for
distribution is MOB-07 and needs the organisation's keystore.

### Try a deep link (MOB-04)

```
adb shell am start -a android.intent.action.VIEW -d "dispatch://items/WI-1042" uk.co.dispatch.app
adb shell am start -a android.intent.action.VIEW -d "dispatch://changes/12" uk.co.dispatch.app
adb shell am start -a android.intent.action.VIEW -d "dispatch://my-week" uk.co.dispatch.app
adb shell am start -a android.intent.action.VIEW -d "https://localhost/mobile/build/web/#/items/WI-1042" uk.co.dispatch.app
```

Signed out, the link is carried through sign-in (`/sign-in?from=…`) and opened afterwards.
The mapping lives in `lib/services/deep_links.dart`; `test/deep_links_test.dart` pins it down.

**https App Links.** The manifest's https filter uses the placeholder `appLinkHost`
(default `localhost`). Set it per deployment and serve the verification file:

```powershell
& "...flutter.bat" build apk --release -P appLinkHost=dispatch.example.org --dart-define=API_BASE=https://dispatch.example.org/api
```

`https://dispatch.example.org/.well-known/assetlinks.json` must name `uk.co.dispatch.app` and
the SHA-256 of the signing certificate (`keytool -list -v -keystore …`). Until it does, Android
shows a chooser for https links; `dispatch://` links open the app directly regardless.

### Try biometric unlock (MOB-05)

On the emulator: Settings → Security → Fingerprint, set a PIN, then enrol with
`adb -e emu finger touch 1`. Sign in; the app offers "Unlock with fingerprint or face?" once.
Turn it on, background the app (Home), wait past the idle period (More → Security → Lock after;
default 5 minutes, or choose Immediately) and return: the lock view covers everything until
`adb -e emu finger touch 1` or the PIN via "Use PIN/passcode instead". Cold start behaves the
same. `MainActivity` extends `FlutterFragmentActivity` because `local_auth`'s BiometricPrompt
requires it. Web and desktop never see the option (`AppLock.supported` is false there).

## iOS

Generated with `flutter create --platforms=ios` and configured for a Mac to build:

- bundle id `uk.co.dispatch.app`, display name Dispatch, deployment target 16.0 (`ios/Runner.xcodeproj/project.pbxproj`);
- `Info.plist`: `CFBundleURLTypes` for the `dispatch` scheme, `FlutterDeepLinkingEnabled`, `NSFaceIDUsageDescription`, `remote-notification` background mode;
- `Runner/Runner.entitlements`: `aps-environment` and an Associated Domains entry (`applinks:localhost` — replace with the real host and serve `/.well-known/apple-app-site-association`).

On a Mac with Xcode 15+: `flutter build ios --release --dart-define=API_BASE=…` (or open
`ios/Runner.xcworkspace` after the first build creates the Podfile and pods) and choose a signing
team. **It has not been built on this machine** — there is no macOS or Xcode here — so nothing
above about iOS has been proven to compile.

## Push notifications (MOB-04) — what is here and what is not

This build ships **no push SDK**. `lib/services/push_service.dart` defines `PushService`, and
`PushService.instance` is a `NoopPushService` that has no token; so nothing registers, and More
says "Push notifications — not available in this build". Everything around it is real:

- `devices.php` (`register` / `unregister` / `list` / `test_push` / `deliveries`) and the
  `DeviceRegistrar` that calls it after sign-in and before sign-out;
- `api/engine/push_lib.php`: `notify()` queues one `push_deliveries` row per active device, and
  `cron_push.php` sends through **FCM HTTP v1** (Android, web) or **APNs** (iOS) when
  `api/config.php` has the `push` keys — otherwise it marks the row `unconfigured` and names the
  missing key. It never reports a push as sent unless the provider returned 2xx;
- deep links from a tapped notification's `link` (`_openLink` in `main.dart` → go_router).

### Enabling push for real

Server: fill `push.fcm_service_account_json` (a Firebase service-account JSON) and/or
`push.apns_key_file` + `apns_key_id` + `apns_team_id` in `api/config.php` (see
`config.example.php`), then schedule `cron_push.php` every minute (the `schtasks` line is in the
file's header).

Client — the two files a Firebase project gives you, which must **not** be faked:

1. `android/app/google-services.json` and, in `android/settings.gradle.kts` /
   `android/app/build.gradle.kts`, the `com.google.gms.google-services` plugin;
2. `ios/Runner/GoogleService-Info.plist` (or skip Firebase on iOS and read the APNs token
   directly — `push_lib.php` sends to APNs natively, so an iOS token registered with
   `platform: 'ios'` needs no Firebase at all).

Then `flutter pub add firebase_core firebase_messaging`, run `flutterfire configure`, and
implement `PushService` once:

```dart
class FirebasePushService implements PushService {
  bool get configured => true;
  String get platform => NoopPushService.platformName();
  String get deviceLabel => NoopPushService.platformLabel();
  Future<void> init({required void Function(String link) onLink}) async {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    await FirebaseMessaging.instance.requestPermission();
    final initial = await FirebaseMessaging.instance.getInitialMessage();     // app opened from a notification
    if (initial?.data['link'] case final String link) onLink(link);
    FirebaseMessaging.onMessageOpenedApp.listen((m) { if (m.data['link'] case final String link) onLink(link); });
    FirebaseMessaging.instance.onTokenRefresh.listen((_) => DeviceRegistrar().register());
  }
  Future<String?> token() => FirebaseMessaging.instance.getToken();
}
```

and set `PushService.instance = FirebasePushService();` at the top of `main()`. Nothing else
changes: registration, the queue, the sender and the deep links are already in place.

## Tests

```powershell
& "...flutter.bat" analyze                              # must say "No issues found!"
& "...flutter.bat" test test/deep_links_test.dart       # deep-link mapping and the biometric lock; no server needed
& "...flutter.bat" test test/screens_smoke_test.dart    # every screen at three widths against the running, seeded API
```

The server-side half is `tests/devices_test.php`, run by `tests/run_all.php`.
