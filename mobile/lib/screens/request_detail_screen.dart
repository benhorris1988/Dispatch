import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/models.dart';
import '../services/api.dart';
import '../services/format.dart';
import '../shell/app_shell.dart';
import '../shell/breaks.dart';
import '../shell/nav.dart';
import '../theme/tokens.dart';
import '../widgets/widgets.dart';
import 'parts/req_request_card.dart';
import 'parts/sch_change_card.dart';

/// One resource request, reachable from a notification link (/requests/12).
class RequestDetailScreen extends StatefulWidget {
  const RequestDetailScreen({super.key, required this.id});
  final String id;

  @override
  State<RequestDetailScreen> createState() => _RequestDetailScreenState();
}

class _RequestDetailScreenState extends State<RequestDetailScreen> {
  ResourceRequest? _request;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  ShellState? _shell;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _shell = context.read<ShellState>();
  }

  @override
  void dispose() {
    // Hand the title back to the route default.
    final shell = _shell;
    if (shell != null) WidgetsBinding.instance.addPostFrameCallback((_) => shell.setPageTitle(null));
    super.dispose();
  }

  @override
  void didUpdateWidget(RequestDetailScreen old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await Api.post('resource_requests.php', 'get', {'id': int.tryParse(widget.id) ?? widget.id});
      if (!mounted) return;
      setState(() {
        _request = ResourceRequest.fromJson(Map<String, dynamic>.from(r['request'] as Map));
        _loading = false;
        _error = null;
      });
      context.read<ShellState>().setPageTitle(
            '${_request!.person.name} for ${_request!.workItem.ref}',
            breadcrumb: const ['Requests'],
          );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _decide(String action) async {
    final r = _request;
    if (r == null) return;
    final reason = await schReasonDialog(
      context,
      title: action == 'approve' ? 'Approve ${r.person.name} for ${r.workItem.ref}' : 'Decline this request',
      message: action == 'approve'
          ? 'This books ${r.person.name} into the committed plan and tells them.'
          : 'Say why, so ${r.requestedByName} knows where they stand.',
      confirmLabel: action == 'approve' ? 'Approve' : 'Decline',
      required: action == 'decline',
    );
    if (reason == null || !mounted) return;
    await _post(action, {'id': r.id, if (reason.isNotEmpty) 'reason': reason});
  }

  Future<void> _withdraw() async {
    final r = _request;
    if (r == null) return;
    await _post('withdraw', {'id': r.id});
  }

  Future<void> _post(String action, Map<String, dynamic> body) async {
    setState(() => _busy = true);
    try {
      final res = await Api.post('resource_requests.php', action, body);
      if (!mounted) return;
      setState(() => _busy = false);
      await _load();
      if (!mounted) return;
      context.read<ShellState>().refreshCounts();
      if (res['over_booked'] == true) {
        _say('Booked. They are over-booked over those dates, so the next planning cycle will move lower-priority work.');
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      if (e.message.contains('freeze horizon') && action == 'approve') {
        final reason = await schReasonDialog(context,
            title: 'Approving inside the freeze horizon', message: e.message, confirmLabel: 'Approve with this reason');
        if (reason != null && reason.isNotEmpty && mounted) {
          await _post(action, {...body, 'reason': reason});
          return;
        }
      }
      _say(e.message);
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const PageBody(child: LoadingState());
    final r = _request;
    if (r == null) {
      return PageBody(child: ErrorState(title: 'That request could not be loaded', message: _error, onRetry: _load));
    }
    return PageBody(
      onRefresh: _load,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PageHeader(
          title: '${r.person.name} for ${r.workItem.ref}',
          subtitle: dotJoin([r.workItem.title, 'asked by ${r.requestedByName}', fmtRelativeDay(r.createdAt)]),
          actions: [
            SecondaryButton('All requests', icon: Icons.list_alt_outlined, onPressed: () => context.go(Routes.requests)),
            SecondaryButton('Open ${r.workItem.ref}', icon: Icons.open_in_new, onPressed: () => context.go(Routes.item(r.workItem.ref))),
          ],
        ),
        const SizedBox(height: Sp.lg),
        ReqRequestCard(
          request: r,
          stacked: Breaks.isPhone(context),
          onApprove: r.canApprove && !_busy ? () => _decide('approve') : null,
          onDecline: r.canApprove && !_busy ? () => _decide('decline') : null,
          onWithdraw: r.canWithdraw && !r.canApprove && !_busy ? _withdraw : null,
        ),
        if (r.isApproved && r.planVersionId != null) ...[
          const SizedBox(height: Sp.md),
          Panel(
            title: 'In the plan',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Approving this wrote committed plan version ${r.planVersionId}, with ${r.person.name} fixed on ${r.workItem.ref} '
                  'for ${fmtDateRange(r.fromDate, r.toDate)}. The engine reproduces a fixed booking rather than planning it away.'),
              const SizedBox(height: Sp.md),
              Wrap(spacing: Sp.sm, runSpacing: Sp.sm, children: [
                SecondaryButton('See the schedule', icon: Icons.calendar_month_outlined, onPressed: () => context.go(Routes.schedule)),
                SecondaryButton('Plan versions', icon: Icons.history, onPressed: () => context.go(PlanVersionsRoute.path(r.planVersionId))),
              ]),
            ]),
          ),
        ],
      ]),
    );
  }
}

/// The plan-versions route with a version preselected, kept here so this screen does not
/// depend on the schedule screen's internals.
class PlanVersionsRoute {
  PlanVersionsRoute._();
  static String path(int? versionId) => versionId == null ? '/schedule/versions' : '/schedule/versions?v=$versionId';
}
