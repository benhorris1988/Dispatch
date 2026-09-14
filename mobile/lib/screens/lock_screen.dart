import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/app_lock.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/widgets.dart';

/// Full-screen lock (MOB-05). Shown by the app builder over everything while
/// [AppLock.locked]; nothing behind it is readable or tappable.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, this.autoPrompt = true});

  /// Ask the OS as soon as the view appears, so a person who enabled the lock is not made
  /// to tap first. Tests turn this off.
  final bool autoPrompt;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.autoPrompt) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<AppLock>().unlock();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final lock = context.watch<AppLock>();
    final session = context.watch<Session>();
    final user = session.user;
    return _Curtain(
      icon: Icons.lock_outline_rounded,
      title: 'Dispatch is locked',
      body: user != null ? 'Signed in as ${user.displayName}. Confirm it is you to continue.' : 'Confirm it is you to continue.',
      error: lock.error,
      children: [
        PrimaryButton(
          'Unlock with fingerprint or face',
          icon: Icons.fingerprint_rounded,
          expand: true,
          busy: lock.authenticating,
          onPressed: lock.authenticating ? null : () => lock.unlock(biometricOnly: true),
        ),
        const SizedBox(height: Sp.sm),
        SecondaryButton(
          'Use PIN/passcode instead',
          expand: true,
          onPressed: lock.authenticating ? null : () => lock.unlock(biometricOnly: false),
        ),
        const SizedBox(height: Sp.xl),
        TextButton(onPressed: lock.authenticating ? null : () => session.signOut(), child: const Text('Sign out')),
      ],
    );
  }
}

/// Shown once after an interactive sign-in on a device that can do it: turn the lock on or not.
class LockOfferScreen extends StatelessWidget {
  const LockOfferScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final lock = context.watch<AppLock>();
    return _Curtain(
      icon: Icons.fingerprint_rounded,
      title: 'Unlock with fingerprint or face?',
      body: 'Dispatch can ask for your fingerprint, face or device PIN when you open it, or when you come back after '
          '${idleLabel(lock.idleMinutes).toLowerCase()} away. Your sign-in stays as it is; this only guards the app on this device.',
      error: lock.error,
      children: [
        PrimaryButton('Turn on', icon: Icons.fingerprint_rounded, expand: true, busy: lock.authenticating, onPressed: lock.authenticating ? null : () => lock.enable()),
        const SizedBox(height: Sp.sm),
        SecondaryButton('Not now', expand: true, onPressed: lock.authenticating ? null : () => lock.dismissOffer()),
        const SizedBox(height: Sp.lg),
        Text('You can change this later under More → Security.', style: context.text.labelSmall, textAlign: TextAlign.center),
      ],
    );
  }
}

/// '5 minutes' / '1 minute' / 'Immediately' for an idle period.
String idleLabel(int minutes) => switch (minutes) { 0 => 'Immediately', 1 => '1 minute', _ => '$minutes minutes' };

class _Curtain extends StatelessWidget {
  const _Curtain({required this.icon, required this.title, required this.body, required this.children, this.error});
  final IconData icon;
  final String title, body;
  final String? error;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.isDark ? DispatchColors.darkBg : DispatchColors.surface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Sp.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Center(child: DispatchLogo(size: 48, onDark: context.isDark)),
                const SizedBox(height: Sp.xxl),
                Icon(icon, size: 44, color: DispatchColors.orange),
                const SizedBox(height: Sp.lg),
                Text(title, style: context.text.headlineMedium, textAlign: TextAlign.center),
                const SizedBox(height: Sp.sm),
                Text(body, style: context.text.bodyMedium?.copyWith(color: context.mutedColor), textAlign: TextAlign.center),
                const SizedBox(height: Sp.xl),
                if (error != null) ...[
                  Container(
                    padding: const EdgeInsets.all(Sp.md),
                    decoration: BoxDecoration(color: DispatchColors.tint(DispatchColors.red), borderRadius: DispatchRadius.cardR),
                    child: Row(children: [
                      const Icon(Icons.error_outline_rounded, color: DispatchColors.red, size: 18),
                      const SizedBox(width: Sp.sm),
                      Expanded(child: Text(error!, style: context.text.bodyMedium?.copyWith(color: DispatchColors.red))),
                    ]),
                  ),
                  const SizedBox(height: Sp.md),
                ],
                ...children,
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
