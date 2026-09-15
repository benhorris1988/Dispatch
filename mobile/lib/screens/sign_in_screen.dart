import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/user.dart';
import '../services/api.dart';
import '../services/google_auth.dart';
import '../shell/breaks.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/widgets.dart';
import '../services/google_button_stub.dart' if (dart.library.js_interop) '../services/google_button_web.dart';

/// Sign-in (ADM-01): the brand pane, and whichever identity providers this
/// deployment actually offers.
///
/// The screen asks the API what to draw rather than assuming. Nothing is
/// hard-coded and nothing is shown disabled: a button that cannot work is a
/// button that should not be on the page, and if none can work the screen says
/// so and names the file to fix.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  late Future<AuthProviders> _providers;
  StreamSubscription<String>? _tokens;
  StreamSubscription<String>? _googleErrors;
  bool _busy = false;
  String? _error;

  /// Set when Google's own SDK refused to start, which is a different problem
  /// from the API being unreachable and needs to say so.
  String? _googleBroken;

  @override
  void initState() {
    super.initState();
    _providers = _load();
  }

  @override
  void dispose() {
    _tokens?.cancel();
    _googleErrors?.cancel();
    super.dispose();
  }

  Future<AuthProviders> _load() async {
    final p = await Api.providers();
    if (!p.googleUsable) return p;
    // Starting Google's SDK is a separate thing from asking the API what it
    // offers, and it is allowed to fail on its own: a bad client id must not be
    // reported as "the API did not answer", which sends somebody looking in
    // entirely the wrong place.
    try {
      await GoogleAuth.instance.initialize(webClientId: p.googleWebClientId!);
      // Both the web button and the native flow finish here, so there is one
      // path into the session however the person signed in.
      _tokens ??= GoogleAuth.instance.idTokens.listen(_completeSignIn);
      _googleErrors ??= GoogleAuth.instance.errors.listen((m) {
        if (mounted && m.isNotEmpty) setState(() => _error = m);
      });
    } catch (e) {
      _googleBroken = GoogleAuth.startupMessageFor(e);
    }
    return p;
  }

  void _reload() => setState(() {
        _error = null;
        _googleBroken = null;
        _providers = _load();
      });

  Future<void> _tapGoogle() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await GoogleAuth.instance.signInNative();
      if (token == null) return; // cancelled: say nothing
      await _completeSignIn(token);
    } catch (e) {
      final m = GoogleAuth.messageFor(e);
      if (mounted && m != null) setState(() => _error = m);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _completeSignIn(String idToken) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<Session>().signInWithGoogle(idToken);
      // The router redirect takes over from here.
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.isNotImplemented
          ? 'Google sign-in is not configured for this environment. Add the client ids to api/config.php.'
          : e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not sign in just now.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = Breaks.wide(context);
    return Scaffold(
      backgroundColor: context.isDark ? DispatchColors.darkBg : DispatchColors.surface,
      body: Row(children: [
        if (Breaks.isDesktop(context)) const Expanded(flex: 5, child: _BrandPane()),
        Expanded(
          flex: 6,
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(wide ? Sp.xxl : Sp.lg),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (!Breaks.isDesktop(context)) ...[
                    Center(child: DispatchLogo(size: 52, onDark: context.isDark)),
                    const SizedBox(height: Sp.xxl),
                  ],
                  Text('Sign in', style: context.text.headlineLarge),
                  const SizedBox(height: 4),
                  Text('Plan and track delivery for your team.', style: context.text.bodyLarge?.copyWith(color: context.mutedColor)),
                  const SizedBox(height: Sp.xl),
                  FutureBuilder<AuthProviders>(
                    future: _providers,
                    builder: (context, snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return const Column(children: [
                          Skeleton(height: 48, radius: DispatchRadius.button),
                          SizedBox(height: Sp.sm),
                          Skeleton(height: 48, radius: DispatchRadius.button),
                        ]);
                      }
                      if (snap.hasError) {
                        final e = snap.error;
                        return ErrorState(
                          compact: true,
                          title: 'Could not reach the sign-in service',
                          message: e is ApiException ? e.message : 'The API at ${Api.base} did not answer.',
                          onRetry: _reload,
                        );
                      }
                      final p = snap.data ?? const AuthProviders();
                      if (!p.any) {
                        return const EmptyState(
                          compact: true,
                          icon: Icons.lock_outline_rounded,
                          title: 'No sign-in method is configured',
                          message: 'Add a Google client id to api/config.php, then reload this page.',
                        );
                      }
                      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        if (p.googleUsable && _googleBroken != null)
                          EmptyState(
                            compact: true,
                            icon: Icons.warning_amber_rounded,
                            title: 'Google sign-in could not start',
                            message: _googleBroken!,
                          )
                        else if (p.googleUsable) ...[
                          // On the web Google renders its own button and we listen
                          // for the result; everywhere else we draw ours and ask.
                          if (kIsWeb)
                            Align(alignment: Alignment.center, child: SizedBox(height: 48, child: googleWebButton()))
                          else
                            _GoogleButton(onPressed: _busy ? null : _tapGoogle, busy: _busy),
                          if (p.googleHostedDomain != null) ...[
                            const SizedBox(height: Sp.sm),
                            Text('Use your ${p.googleHostedDomain} account.',
                                textAlign: TextAlign.center, style: context.text.bodySmall?.copyWith(color: context.mutedColor)),
                          ],
                        ],
                        if (p.microsoftEnabled) ...[
                          const SizedBox(height: Sp.md),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : () => setState(() => _error = 'Microsoft sign-in is configured on the server but not yet wired into this app.'),
                            icon: const _MicrosoftGlyph(),
                            label: const Text('Sign in with Microsoft'),
                            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                          ),
                        ],
                      ]);
                    },
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: Sp.lg),
                    Container(
                      padding: const EdgeInsets.all(Sp.md),
                      decoration: BoxDecoration(color: DispatchColors.tint(DispatchColors.red), borderRadius: DispatchRadius.cardR),
                      child: Row(children: [
                        const Icon(Icons.error_outline_rounded, color: DispatchColors.red, size: 18),
                        const SizedBox(width: Sp.sm),
                        Expanded(child: Text(_error!, style: context.text.bodyMedium?.copyWith(color: DispatchColors.red))),
                      ]),
                    ),
                  ],
                  const SizedBox(height: Sp.xl),
                  Text('Accounts are created the first time somebody signs in.',
                      style: context.text.labelSmall, textAlign: TextAlign.center),
                  const SizedBox(height: 2),
                  Text('API: ${Api.base}', style: context.text.labelSmall, textAlign: TextAlign.center),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// The native sign-in button. White ground, Google's own mark, their grey
/// border: their branding rules, which is why it does not use our palette.
class _GoogleButton extends StatelessWidget {
  const _GoogleButton({this.onPressed, this.busy = false});
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: busy
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : Image.asset('assets/google_g.png', width: 18, height: 18),
      label: const Text('Sign in with Google'),
      style: OutlinedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1F1F1F),
        side: const BorderSide(color: Color(0xFF747775)),
        padding: const EdgeInsets.symmetric(vertical: 14),
        textStyle: context.text.titleSmall,
      ),
    );
  }
}

class _BrandPane extends StatelessWidget {
  const _BrandPane();
  @override
  Widget build(BuildContext context) {
    return Container(
      color: DispatchColors.ink,
      padding: const EdgeInsets.all(56),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const DispatchLogo(size: 52),
        const Spacer(),
        Text('Plans that hold.', style: context.text.displayMedium?.copyWith(color: Colors.white)),
        const SizedBox(height: Sp.md),
        Text(
          'Dispatch schedules the team\'s work, keeps changes to a budget, and shows everyone what lands when.',
          style: context.text.bodyLarge?.copyWith(color: DispatchColors.sidebarMuted),
        ),
        const SizedBox(height: Sp.xxl),
        Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: const [
          _Fact('Committed plan', 'Frozen for 10 working days'),
          _Fact('Nightly replan', 'Proposed at 02:00, you decide'),
          _Fact('Change budget', '5 days a week, no more'),
        ]),
      ]),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.title, this.body);
  final String title, body;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      padding: const EdgeInsets.all(Sp.md),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.06), borderRadius: DispatchRadius.cardR, border: Border.all(color: Colors.white.withValues(alpha: 0.1))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: context.text.titleSmall?.copyWith(color: Colors.white)),
        const SizedBox(height: 2),
        Text(body, style: context.text.bodySmall?.copyWith(color: DispatchColors.sidebarMuted)),
      ]),
    );
  }
}

/// Four-square Microsoft glyph, for the day a tenant is configured.
class _MicrosoftGlyph extends StatelessWidget {
  const _MicrosoftGlyph();
  @override
  Widget build(BuildContext context) {
    Widget sq(Color c) => Container(width: 8, height: 8, color: c);
    return SizedBox(
      width: 18,
      height: 18,
      child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [sq(const Color(0xFFF25022)), sq(const Color(0xFF7FBA00))]),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [sq(const Color(0xFF00A4EF)), sq(const Color(0xFFFFB900))]),
      ]),
    );
  }
}
