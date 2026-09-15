import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Google sign-in (ADM-01), the one identity provider this iteration offers.
///
/// Two shapes of the same flow. On Android and iOS we ask for an account and get
/// one back; on the web the plugin renders Google's own button and the account
/// arrives later on a stream, because Google's web SDK owns that interaction and
/// will not be driven from Dart. Both paths end in the same place: an ID token
/// handed to `auth.php google_login`, which verifies it and issues ours. The
/// token is never stored and never leaves that one request.
///
/// The client ids are not compiled in. `auth.php providers` hands over the web
/// client id at runtime, so the same build works against any deployment, and the
/// native apps send that same id as their *server* client id — which is what
/// makes the token they receive carry an audience the API accepts.
class GoogleAuth {
  GoogleAuth._();
  static final GoogleAuth instance = GoogleAuth._();

  bool _initialised = false;
  String? _clientId;
  StreamSubscription<GoogleSignInAuthenticationEvent>? _sub;
  final StreamController<String> _idTokens = StreamController<String>.broadcast();

  /// ID tokens as they arrive, from either path. The web button completes only
  /// through here, so the sign-in screen listens rather than awaiting.
  Stream<String> get idTokens => _idTokens.stream;

  /// Problems Google reports that are not a cancellation, so the screen can say
  /// something truthful instead of failing silently.
  final StreamController<String> _errors = StreamController<String>.broadcast();
  Stream<String> get errors => _errors.stream;

  bool get isReady => _initialised;

  /// Idempotent, and safe to call again with the same id: the plugin may only be
  /// initialised once per process.
  Future<void> initialize({required String webClientId}) async {
    if (_initialised && _clientId == webClientId) return;
    if (_initialised) return; // a second, different id would be a misconfiguration, not a retry
    await GoogleSignIn.instance.initialize(
      clientId: kIsWeb ? webClientId : null,
      serverClientId: kIsWeb ? null : webClientId,
    );
    _clientId = webClientId;
    _initialised = true;
    _sub ??= GoogleSignIn.instance.authenticationEvents.listen(
      (event) {
        if (event is! GoogleSignInAuthenticationEventSignIn) return;
        final token = event.user.authentication.idToken;
        if (token != null && token.isNotEmpty) {
          _idTokens.add(token);
        } else {
          // An account with no ID token means the server client id is missing or
          // does not match; saying so beats an empty screen.
          _errors.add('Google did not return an identity token. Check the client ids in api/config.php.');
        }
      },
      onError: (Object e) => _errors.add(_message(e)),
    );
  }

  /// Android and iOS. Returns the ID token, or null when the person changed
  /// their mind — a cancellation is not an error and should say nothing.
  Future<String?> signInNative() async {
    if (kIsWeb) return null; // the web button owns its own flow
    try {
      final account = await GoogleSignIn.instance.authenticate(scopeHint: const ['email']);
      return account.authentication.idToken;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }
  }

  /// Sign out of Google as well as Dispatch, so the next sign-in offers the
  /// account chooser rather than silently returning the same person.
  Future<void> signOut() async {
    if (!_initialised) return;
    try {
      await GoogleSignIn.instance.signOut();
    } catch (e) {
      debugPrint('[google] sign-out failed: $e');
    }
  }

  static String _message(Object e) {
    if (e is GoogleSignInException) {
      return switch (e.code) {
        GoogleSignInExceptionCode.canceled => '',
        GoogleSignInExceptionCode.uiUnavailable => 'Google sign-in is not available on this device.',
        _ => e.description ?? 'Google sign-in did not complete. Please try again.',
      };
    }
    return 'Google sign-in did not complete. Please try again.';
  }

  /// A message fit to show somebody, or null when they simply cancelled.
  static String? messageFor(Object e) {
    final m = _message(e);
    return m.isEmpty ? null : m;
  }

  /// Why the SDK would not start at all. Almost always a client id that the
  /// Google Cloud project does not recognise, or an origin missing from it, so
  /// say where to look rather than offering a pointless 'try again'.
  static String startupMessageFor(Object e) {
    final detail = e is GoogleSignInException ? (e.description ?? '') : '';
    const where = 'Check google.client_ids in api/config.php, and that this address is an authorised JavaScript origin on the web client.';
    if (detail.isEmpty) return where;
    return '$detail\n\n$where';
  }
}
