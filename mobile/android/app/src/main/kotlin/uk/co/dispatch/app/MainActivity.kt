package uk.co.dispatch.app

import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity rather than FlutterActivity: local_auth's BiometricPrompt needs a
// FragmentActivity to attach to (MOB-05).
class MainActivity : FlutterFragmentActivity()
