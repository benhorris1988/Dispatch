import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Biometric unlock for the app session (MOB-05).
///
/// The identity-provider session (the API token) is untouched: this guards *showing* it.
/// When enabled, the app is locked on cold start and when it returns from the background
/// after [idleMinutes] away; [unlock] asks the OS for a fingerprint, face or — with
/// `biometricOnly: false` — the device PIN/passcode. The preference lives in
/// shared_preferences on this device only.
///
/// The OS prompt is behind [BiometricGate] so the lock can be driven in tests.
class AppLock extends ChangeNotifier with WidgetsBindingObserver {
  AppLock({BiometricGate? gate, DateTime Function()? clock})
      : _gate = gate ?? LocalAuthGate(),
        _clock = clock ?? DateTime.now;

  static const String kEnabled = 'dispatch.lock.enabled';
  static const String kIdleMinutes = 'dispatch.lock.idleMinutes';
  static const String kOffered = 'dispatch.lock.offered';

  static const int defaultIdleMinutes = 5;

  /// Idle periods offered in More → Security. 0 means every time.
  static const List<int> idleChoices = [0, 1, 5, 15, 30];

  final BiometricGate _gate;
  final DateTime Function() _clock;

  bool _loaded = false;
  bool _supported = false;
  bool _enabled = false;
  bool _locked = false;
  bool _offered = false;
  bool _offerPending = false;
  bool _authenticating = false;
  int _idleMinutes = defaultIdleMinutes;
  String? _error;
  DateTime? _pausedAt;

  bool get loaded => _loaded;

  /// The device can do biometrics or a device credential. Always false on web and desktop.
  bool get supported => _supported;
  bool get enabled => _enabled;

  /// True while the lock view must cover the app.
  bool get locked => _locked;

  /// True right after an interactive sign-in on a capable device where the user has never
  /// been asked: the offer view shows once.
  bool get offerPending => _offerPending;
  bool get authenticating => _authenticating;
  int get idleMinutes => _idleMinutes;

  /// Plain-English reason the last prompt did not succeed, for the lock view.
  String? get error => _error;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _enabled = p.getBool(kEnabled) ?? false;
    _idleMinutes = p.getInt(kIdleMinutes) ?? defaultIdleMinutes;
    _offered = p.getBool(kOffered) ?? false;
    _supported = await _gate.supported();
    // Cold start: nothing is shown until the user confirms it is them.
    _locked = _enabled && _supported;
    _loaded = true;
    notifyListeners();
  }

  /// Start watching the app lifecycle. Call once after [load].
  void attach() => WidgetsBinding.instance.addObserver(this);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The OS prompt itself pauses the app on some devices; do not count that as leaving.
    if (!_enabled || _authenticating) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _pausedAt ??= _clock();
    } else if (state == AppLifecycleState.resumed) {
      final at = _pausedAt;
      _pausedAt = null;
      if (at != null && !_locked && _clock().difference(at) >= Duration(minutes: _idleMinutes)) {
        _locked = true;
        notifyListeners();
      }
    }
  }

  /// Ask the OS to confirm the user. With [biometricOnly] false the OS offers the device
  /// PIN/passcode as well ("Use PIN/passcode instead").
  Future<bool> unlock({bool biometricOnly = false}) async {
    if (_authenticating) return false;
    _authenticating = true;
    _error = null;
    notifyListeners();
    try {
      final ok = await _gate.authenticate(reason: 'Unlock Dispatch', biometricOnly: biometricOnly);
      if (ok) {
        _locked = false;
        _pausedAt = null;
      } else {
        _error = 'Not recognised. Try again, or use your PIN or passcode.';
      }
      return ok;
    } on BiometricUnavailable catch (e) {
      _error = e.message;
      return false;
    } finally {
      _authenticating = false;
      notifyListeners();
    }
  }

  /// Turn the lock on. The user must pass the prompt once first, so it is never enabled on a
  /// device where it could not then be passed.
  Future<bool> enable() async {
    if (!_supported || _authenticating) return false;
    _authenticating = true;
    _error = null;
    notifyListeners();
    try {
      final ok = await _gate.authenticate(reason: 'Confirm to turn on biometric unlock', biometricOnly: false);
      if (!ok) {
        _error = 'Not recognised, so biometric unlock stays off.';
        return false;
      }
      _enabled = true;
      _offerPending = false;
      _offered = true;
      await _persist();
      return true;
    } on BiometricUnavailable catch (e) {
      _error = e.message;
      return false;
    } finally {
      _authenticating = false;
      notifyListeners();
    }
  }

  Future<void> disable() async {
    _enabled = false;
    _locked = false;
    _pausedAt = null;
    _error = null;
    await _persist();
    notifyListeners();
  }

  Future<void> setIdleMinutes(int minutes) async {
    _idleMinutes = minutes < 0 ? 0 : minutes;
    await _persist();
    notifyListeners();
  }

  /// An interactive sign-in has just succeeded: the user has proved who they are, so the
  /// app is not locked; offer the lock once on a capable device.
  void onSignedIn() {
    _locked = false;
    _pausedAt = null;
    _error = null;
    if (_supported && !_enabled && !_offered) _offerPending = true;
    notifyListeners();
  }

  Future<void> dismissOffer() async {
    _offerPending = false;
    _offered = true;
    await _persist();
    notifyListeners();
  }

  /// Signed out: there is nothing to guard. The preference stays for the next sign-in.
  void onSignedOut() {
    _locked = false;
    _offerPending = false;
    _pausedAt = null;
    _error = null;
    notifyListeners();
  }

  /// Lock immediately (a "Lock now" control, or a test).
  void lockNow() {
    if (!_enabled || _locked) return;
    _locked = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kEnabled, _enabled);
    await p.setInt(kIdleMinutes, _idleMinutes);
    await p.setBool(kOffered, _offered);
  }
}

/// The OS-level prompt. [LocalAuthGate] is the real one; tests substitute a fake.
abstract class BiometricGate {
  /// Whether the device can authenticate at all (biometrics or a device credential).
  Future<bool> supported();

  /// True when the user passed. Throws [BiometricUnavailable] when the prompt could not be
  /// shown (nothing enrolled, locked out, no passcode), with a message the UI can display.
  Future<bool> authenticate({required String reason, required bool biometricOnly});
}

class BiometricUnavailable implements Exception {
  BiometricUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// local_auth on Android and iOS; reports unsupported everywhere else, so web and desktop
/// never see the option.
class LocalAuthGate implements BiometricGate {
  LocalAuthGate([LocalAuthentication? auth]) : _auth = auth ?? LocalAuthentication();
  final LocalAuthentication _auth;

  bool get _mobile => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Future<bool> supported() async {
    if (!_mobile) return false;
    try {
      return await _auth.isDeviceSupported() || await _auth.canCheckBiometrics;
    } catch (e) {
      debugPrint('[lock] capability check failed: $e');
      return false;
    }
  }

  @override
  Future<bool> authenticate({required String reason, required bool biometricOnly}) async {
    try {
      return await _auth.authenticate(localizedReason: reason, biometricOnly: biometricOnly, persistAcrossBackgrounding: true);
    } on PlatformException catch (e) {
      throw BiometricUnavailable(describe(e.code));
    }
  }

  /// local_auth error codes → what to tell the person.
  static String describe(String code) => switch (code) {
        'NotAvailable' => 'Biometrics are not available on this device.',
        'NotEnrolled' => 'No fingerprint or face is enrolled. Add one in your device settings, or use your PIN.',
        'LockedOut' => 'Too many attempts. Wait a moment, or use your PIN or passcode.',
        'PermanentlyLockedOut' => 'Biometrics are locked. Unlock your device with its PIN or passcode first.',
        'PasscodeNotSet' => 'Set a device PIN or passcode to use biometric unlock.',
        _ => 'Could not check your identity ($code).',
      };
}
