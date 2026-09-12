import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/user.dart';
import '../services/api.dart';
import '../shell/breaks.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/widgets.dart';

/// Sign-in: logo, a disabled Microsoft button, and the development sign-in
/// list of seeded users.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  late Future<List<DevUser>> _users;
  int? _busyId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _users = Api.listDevUsers();
  }

  void _reload() => setState(() {
        _error = null;
        _users = Api.listDevUsers();
      });

  Future<void> _signIn(DevUser u) async {
    setState(() {
      _busyId = u.id;
      _error = null;
    });
    try {
      await context.read<Session>().signInDev(u.id);
      // Router redirect takes over.
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Could not sign in just now.');
    } finally {
      if (mounted) setState(() => _busyId = null);
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
                  Tooltip(
                    message: 'Entra ID not configured in this environment',
                    child: OutlinedButton.icon(
                      onPressed: null,
                      icon: const _MicrosoftGlyph(),
                      label: const Text('Sign in with Microsoft'),
                      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                    ),
                  ),
                  const SizedBox(height: Sp.xl),
                  Row(children: [
                    const Expanded(child: Divider()),
                    Padding(padding: const EdgeInsets.symmetric(horizontal: Sp.md), child: Text('Development sign-in', style: context.text.labelMedium?.copyWith(color: context.mutedColor))),
                    const Expanded(child: Divider()),
                  ]),
                  const SizedBox(height: Sp.lg),
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(Sp.md),
                      decoration: BoxDecoration(color: DispatchColors.tint(DispatchColors.red), borderRadius: DispatchRadius.cardR),
                      child: Row(children: [
                        const Icon(Icons.error_outline_rounded, color: DispatchColors.red, size: 18),
                        const SizedBox(width: Sp.sm),
                        Expanded(child: Text(_error!, style: context.text.bodyMedium?.copyWith(color: DispatchColors.red))),
                      ]),
                    ),
                    const SizedBox(height: Sp.md),
                  ],
                  FutureBuilder<List<DevUser>>(
                    future: _users,
                    builder: (context, snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return Column(children: [for (var i = 0; i < 3; i++) const Padding(padding: EdgeInsets.only(bottom: Sp.sm), child: Skeleton(height: 64, radius: DispatchRadius.card))]);
                      }
                      if (snap.hasError) {
                        final e = snap.error;
                        return ErrorState(
                          compact: true,
                          title: 'Could not load users',
                          message: e is ApiException ? e.message : 'The API at ${Api.base} did not answer.',
                          onRetry: _reload,
                        );
                      }
                      final users = snap.data ?? const [];
                      if (users.isEmpty) return const EmptyState(compact: true, title: 'No development users', message: 'Seed the database to add some.');
                      return Column(children: [
                        for (final u in users) Padding(padding: const EdgeInsets.only(bottom: Sp.sm), child: _DevUserCard(user: u, busy: _busyId == u.id, enabled: _busyId == null, onTap: () => _signIn(u))),
                      ]);
                    },
                  ),
                  const SizedBox(height: Sp.xl),
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

class _DevUserCard extends StatelessWidget {
  const _DevUserCard({required this.user, required this.onTap, this.busy = false, this.enabled = true});
  final DevUser user;
  final VoidCallback onTap;
  final bool busy, enabled;

  @override
  Widget build(BuildContext context) {
    return DispatchCard(
      onTap: enabled ? onTap : null,
      padding: const EdgeInsets.symmetric(horizontal: Sp.md, vertical: Sp.md),
      child: Row(children: [
        PersonAvatar(user.initialsOrDerived, colourHex: user.colour, seed: user.id, size: 40),
        const SizedBox(width: Sp.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(user.displayName, style: context.text.titleMedium),
            const SizedBox(height: 2),
            Text([user.roleTitle, roleLabel(user.role)].where((s) => s != null && s.isNotEmpty).toSet().join(' · '),
                style: context.text.bodySmall),
          ]),
        ),
        if (busy)
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        else
          Icon(Icons.chevron_right_rounded, color: context.mutedColor),
      ]),
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

/// Four-square Microsoft glyph.
class _MicrosoftGlyph extends StatelessWidget {
  const _MicrosoftGlyph();
  @override
  Widget build(BuildContext context) {
    Widget sq(Color c) => Container(width: 8, height: 8, color: c);
    return Opacity(
      opacity: 0.6,
      child: SizedBox(
        width: 18,
        height: 18,
        child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [sq(const Color(0xFFF25022)), sq(const Color(0xFF7FBA00))]),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [sq(const Color(0xFF00A4EF)), sq(const Color(0xFFFFB900))]),
        ]),
      ),
    );
  }
}
