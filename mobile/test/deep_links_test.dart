// Deep-link route mapping (MOB-04) and the biometric lock (MOB-05).
//
//   flutter test test/deep_links_test.dart
//
// No server and no device: the OS prompt is behind BiometricGate, so a fake stands in for
// it, and DeepLinks.toRoute is a pure function.
import 'package:dispatch_app/app_state.dart';
import 'package:dispatch_app/screens/lock_screen.dart';
import 'package:dispatch_app/services/app_lock.dart';
import 'package:dispatch_app/services/deep_links.dart';
import 'package:dispatch_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Scripted OS prompt: answers [result], records what it was asked.
class FakeGate implements BiometricGate {
  FakeGate({this.isSupported = true, this.result = true});
  bool isSupported;
  bool result;
  Object? throwWith;
  int calls = 0;
  bool? lastBiometricOnly;

  @override
  Future<bool> supported() async => isSupported;

  @override
  Future<bool> authenticate({required String reason, required bool biometricOnly}) async {
    calls++;
    lastBiometricOnly = biometricOnly;
    if (throwWith != null) throw throwWith!;
    return result;
  }
}

/// A clock the tests can move.
class FakeClock {
  DateTime now = DateTime(2026, 9, 8, 9, 0);
  void advance(Duration d) => now = now.add(d);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  group('DeepLinks.toRoute', () {
    String? route(String s) => DeepLinks.toRoute(Uri.parse(s));

    test('custom scheme links land on the item, change and My week', () {
      expect(route('dispatch://items/WI-1042'), '/items/WI-1042');
      expect(route('dispatch://changes/12'), '/changes/12');
      expect(route('dispatch://my-week'), '/my-week');
      expect(route('dispatch://items/WI-1042/estimate'), '/items/WI-1042/estimate');
      expect(route('dispatch://people/3'), '/people/3');
    });

    test('the triple-slash form and a trailing slash are tolerated', () {
      expect(route('dispatch:///items/WI-1042'), '/items/WI-1042');
      expect(route('dispatch://changes/12/'), '/changes/12');
    });

    test('a query string survives', () {
      expect(route('dispatch://pipeline?q=ingest'), '/pipeline?q=ingest');
      expect(route('https://localhost/mobile/build/web/#/schedule/versions?v=7'), '/schedule/versions?v=7');
    });

    test('https App Links to the hosted web build map by fragment or by path', () {
      expect(route('https://dispatch.example.org/mobile/build/web/#/items/WI-1042'), '/items/WI-1042');
      expect(route('https://dispatch.example.org/mobile/build/web/changes/12'), '/changes/12');
      expect(route('https://dispatch.example.org/mobile/build/web/'), isNull, reason: 'the bare web root is not a screen');
    });

    test("a notification's link is already an app path", () {
      expect(route('/items/WI-1042'), '/items/WI-1042');
      expect(route('/changes/12'), '/changes/12');
      expect(route('/notifications'), '/notifications');
    });

    test('anything that is not a Dispatch route is refused rather than shown as Page not found', () {
      expect(route('dispatch://nonsense'), isNull);
      expect(route('dispatch://items'), isNull);
      expect(route('dispatch://changes/twelve'), isNull);
      expect(route('mailto:someone@example.org'), isNull);
      expect(route('https://dispatch.example.org/other/path'), isNull);
      expect(route('/sign-in'), isNull, reason: 'sign-in is not a destination a link may force');
    });

    test('needsMapping is true only for links from outside', () {
      expect(DeepLinks.needsMapping(Uri.parse('dispatch://my-week')), isTrue);
      expect(DeepLinks.needsMapping(Uri.parse('https://h/mobile/build/web/#/my-week')), isTrue);
      expect(DeepLinks.needsMapping(Uri.parse('/mobile/build/web/my-week')), isTrue);
      expect(DeepLinks.needsMapping(Uri.parse('/my-week')), isFalse);
    });
  });

  group('AppLock', () {
    test('a device that cannot authenticate never offers or locks', () async {
      SharedPreferences.setMockInitialValues({AppLock.kEnabled: true});
      final lock = AppLock(gate: FakeGate(isSupported: false));
      await lock.load();
      expect(lock.supported, isFalse);
      expect(lock.locked, isFalse);
      lock.onSignedIn();
      expect(lock.offerPending, isFalse);
    });

    test('cold start with the lock on shows the lock before anything else', () async {
      SharedPreferences.setMockInitialValues({AppLock.kEnabled: true});
      final lock = AppLock(gate: FakeGate());
      await lock.load();
      expect(lock.enabled, isTrue);
      expect(lock.locked, isTrue);
    });

    test('resuming after the idle period locks; resuming sooner does not', () async {
      SharedPreferences.setMockInitialValues({AppLock.kEnabled: true, AppLock.kIdleMinutes: 5});
      final clock = FakeClock();
      final gate = FakeGate();
      final lock = AppLock(gate: gate, clock: () => clock.now);
      await lock.load();
      expect(await lock.unlock(), isTrue);
      expect(lock.locked, isFalse);

      lock.didChangeAppLifecycleState(AppLifecycleState.paused);
      clock.advance(const Duration(minutes: 4, seconds: 59));
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(lock.locked, isFalse, reason: 'under five minutes away');

      lock.didChangeAppLifecycleState(AppLifecycleState.hidden);
      clock.advance(const Duration(minutes: 5));
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(lock.locked, isTrue, reason: 'five minutes away');
    });

    test('an idle period of 0 locks on every return', () async {
      SharedPreferences.setMockInitialValues({AppLock.kEnabled: true, AppLock.kIdleMinutes: 0});
      final clock = FakeClock();
      final lock = AppLock(gate: FakeGate(), clock: () => clock.now);
      await lock.load();
      await lock.unlock();
      lock.didChangeAppLifecycleState(AppLifecycleState.paused);
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(lock.locked, isTrue);
    });

    test('a failed prompt keeps the lock and explains; an unavailable prompt explains why', () async {
      SharedPreferences.setMockInitialValues({AppLock.kEnabled: true});
      final gate = FakeGate(result: false);
      final lock = AppLock(gate: gate);
      await lock.load();
      expect(await lock.unlock(biometricOnly: true), isFalse);
      expect(lock.locked, isTrue);
      expect(lock.error, contains('Not recognised'));
      gate.throwWith = BiometricUnavailable(LocalAuthGate.describe('LockedOut'));
      expect(await lock.unlock(), isFalse);
      expect(lock.error, contains('Too many attempts'));
    });

    test('enable needs one successful prompt and persists; disable clears the lock', () async {
      SharedPreferences.setMockInitialValues({});
      final gate = FakeGate(result: false);
      final lock = AppLock(gate: gate);
      await lock.load();
      expect(await lock.enable(), isFalse);
      expect(lock.enabled, isFalse);
      gate.result = true;
      expect(await lock.enable(), isTrue);
      expect(lock.enabled, isTrue);
      final p = await SharedPreferences.getInstance();
      expect(p.getBool(AppLock.kEnabled), isTrue);
      expect(p.getBool(AppLock.kOffered), isTrue);
      lock.lockNow();
      expect(lock.locked, isTrue);
      await lock.disable();
      expect(lock.enabled, isFalse);
      expect(lock.locked, isFalse);
      expect(p.getBool(AppLock.kEnabled), isFalse);
    });

    test('the offer appears once, after an interactive sign-in, and never again once answered', () async {
      SharedPreferences.setMockInitialValues({});
      final lock = AppLock(gate: FakeGate());
      await lock.load();
      expect(lock.offerPending, isFalse);
      lock.onSignedIn();
      expect(lock.offerPending, isTrue);
      await lock.dismissOffer();
      expect(lock.offerPending, isFalse);
      lock.onSignedOut();
      lock.onSignedIn();
      expect(lock.offerPending, isFalse, reason: 'answered already');
    });
  });

  group('Lock views', () {
    Widget host(AppLock lock, Widget child) => MultiProvider(
          providers: [
            ChangeNotifierProvider<Session>(create: (_) => Session()),
            ChangeNotifierProvider<AppLock>.value(value: lock),
          ],
          child: MaterialApp(theme: DispatchTheme.light(), home: child),
        );

    testWidgets('the lock view offers biometrics, the OS PIN fallback and sign out', (tester) async {
      SharedPreferences.setMockInitialValues({AppLock.kEnabled: true});
      final gate = FakeGate();
      final lock = AppLock(gate: gate);
      await lock.load();
      await tester.pumpWidget(host(lock, const LockScreen(autoPrompt: false)));
      await tester.pump();

      expect(find.text('Dispatch is locked'), findsOneWidget);
      expect(find.text('Unlock with fingerprint or face'), findsOneWidget);
      expect(find.text('Use PIN/passcode instead'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
      expect(gate.calls, 0, reason: 'autoPrompt is off');

      await tester.tap(find.text('Use PIN/passcode instead'));
      await tester.pumpAndSettle();
      expect(gate.calls, 1);
      expect(gate.lastBiometricOnly, isFalse, reason: 'the PIN route lets the OS fall back to the device credential');
      expect(lock.locked, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the biometric button asks for biometrics only, and a refusal is explained in place', (tester) async {
      SharedPreferences.setMockInitialValues({AppLock.kEnabled: true});
      final gate = FakeGate(result: false);
      final lock = AppLock(gate: gate);
      await lock.load();
      await tester.pumpWidget(host(lock, const LockScreen(autoPrompt: false)));
      await tester.pump();
      await tester.tap(find.text('Unlock with fingerprint or face'));
      await tester.pumpAndSettle();
      expect(gate.lastBiometricOnly, isTrue);
      expect(lock.locked, isTrue);
      expect(find.textContaining('Not recognised'), findsOneWidget);
    });

    testWidgets('the lock view prompts on appearance by default', (tester) async {
      SharedPreferences.setMockInitialValues({AppLock.kEnabled: true});
      final gate = FakeGate();
      final lock = AppLock(gate: gate);
      await lock.load();
      await tester.pumpWidget(host(lock, const LockScreen()));
      await tester.pumpAndSettle();
      expect(gate.calls, 1);
      expect(lock.locked, isFalse);
    });

    testWidgets('the offer view can be declined and remembers that', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final lock = AppLock(gate: FakeGate());
      await lock.load();
      lock.onSignedIn();
      expect(lock.offerPending, isTrue);
      await tester.pumpWidget(host(lock, const LockOfferScreen()));
      await tester.pump();
      expect(find.text('Unlock with fingerprint or face?'), findsOneWidget);
      expect(find.textContaining('5 minutes away'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(lock.offerPending, isFalse);
      expect((await SharedPreferences.getInstance()).getBool(AppLock.kOffered), isTrue);
    });

    testWidgets('the offer view turns the lock on after one successful prompt', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final gate = FakeGate();
      final lock = AppLock(gate: gate);
      await lock.load();
      lock.onSignedIn();
      await tester.pumpWidget(host(lock, const LockOfferScreen()));
      await tester.pump();
      await tester.tap(find.text('Turn on'));
      await tester.pumpAndSettle();
      expect(gate.calls, 1);
      expect(lock.enabled, isTrue);
      expect(lock.offerPending, isFalse);
    });
  });
}
