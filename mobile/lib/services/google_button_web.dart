import 'package:flutter/widgets.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:google_sign_in_web/google_sign_in_web.dart' as web;

/// Google's own sign-in button, rendered by their web SDK.
///
/// It is an HTML element, not a Flutter widget: it will not take Inter, our
/// 8px radius or our palette, and Google's branding rules would not allow us to
/// restyle it anyway. The outline theme at large size is the closest fit to the
/// rest of the sign-in column. Pressing it completes through
/// `GoogleAuth.idTokens`, not through a callback.
Widget googleWebButton({VoidCallback? onPressed}) {
  final plugin = GoogleSignInPlatform.instance;
  if (plugin is! web.GoogleSignInPlugin) return const SizedBox.shrink();
  return plugin.renderButton(
    configuration: web.GSIButtonConfiguration(
      theme: web.GSIButtonTheme.outline,
      size: web.GSIButtonSize.large,
      shape: web.GSIButtonShape.rectangular,
      text: web.GSIButtonText.signinWith,
      logoAlignment: web.GSIButtonLogoAlignment.left,
      minimumWidth: 400,
    ),
  );
}
