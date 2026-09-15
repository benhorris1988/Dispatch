import 'package:flutter/widgets.dart';

/// Placeholder for the web-only Google button. On Android and iOS the app uses
/// its own button and [GoogleAuth.signInNative], so nothing here is ever built —
/// this file exists so the web plugin's JavaScript interop never reaches a
/// mobile compile.
Widget googleWebButton({VoidCallback? onPressed}) => const SizedBox.shrink();
