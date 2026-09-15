import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/models.dart';
import '../services/api.dart';
import '../shell/app_shell.dart';
import '../shell/breaks.dart';
import '../shell/nav.dart';
import '../theme/tokens.dart';
import '../widgets/widgets.dart';
import 'parts/req_request_card.dart';
import 'parts/sch_change_card.dart';

/// Resource requests — somebody has asked for a named person's time, and a lead
/// above that person decides.
///
/// Three views, because three different questions get asked of this screen:
/// what is waiting on me, what am I waiting for, and what has been asked lately.
/// "For my approval" is served by the API rather than filtered here: only the
/// server knows the team tree, so only the server can say what this caller may
/// actually decide.
class RequestsScreen extends StatefulWidget {
  const RequestsScreen({super.key});

  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends State<RequestsScreen> {
  List<ResourceRequest> _requests = const [];
  int _pendingForMe = 0;
  int _minePending = 0;
  int _tab = 0;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool get _isLead => context.read<Session>().isTeamLead;
  List<String> get _tabs => _isLead ? const ['For my approval', 'Mine', 'All'] : const ['Mine'];
  String get _view => _isLead ? const ['for_me', 'mine', 'all'][_tab] : 'mine';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Whatever screen we came from may have set a custom title (a work item sets its ref);
      // the shell keeps it until somebody says otherwise.
      context.read<ShellState>().setPageTitle('Requests');
      _load();
    });
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final r = await Api.post('resource_requests.php', 'list', {
        'view': _view,
        if (_view == 'for_me') 'status': 'pending',
      });
      if (!mounted) return;
      setState(() {
        _requests = asList(r['requests'], ResourceRequest.fromJson);
        _pendingForMe = (r['counts']?['pending_for_me'] as num?)?.toInt() ?? 0;
        _minePending = (r['counts']?['mine_pending'] as num?)?.toInt() ?? 0;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _decide(ResourceRequest r, String action) async {
    // Declining always owes the asker a reason; approving needs one only inside the
    // freeze horizon, and the server is the judge of that — so ask optionally and let
    // it come back 409 with `reason_required` if it insists.
    final reason = await schReasonDialog(
      context,
      title: action == 'approve' ? 'Approve ${r.person.name} for ${r.workItem.ref}' : 'Decline this request',
      message: action == 'approve'
          ? 'This books ${r.person.name} into the committed plan and tells them. ${r.requestedByName} is told either way.'
          : 'Say why, so ${r.requestedByName} knows where they stand.',
      confirmLabel: action == 'approve' ? 'Approve' : 'Decline',
      required: action == 'decline',
    );
    if (reason == null || !mounted) return;
    await _post(action, r, {'id': r.id, if (reason.isNotEmpty) 'reason': reason});
  }

  Future<void> _withdraw(ResourceRequest r) async {
    final reason = await schReasonDialog(context,
        title: 'Withdraw this request', message: 'It disappears from the approver\'s queue.', confirmLabel: 'Withdraw', required: false);
    if (reason == null || !mounted) return;
    await _post('withdraw', r, {'id': r.id, if (reason.isNotEmpty) 'reason': reason});
  }

  Future<void> _post(String action, ResourceRequest r, Map<String, dynamic> body) async {
    setState(() => _busy = true);
    try {
      final res = await Api.post('resource_requests.php', action, body);
      if (!mounted) return;
      setState(() => _busy = false);
      await _load(silent: true);
      if (!mounted) return;
      context.read<ShellState>().refreshCounts();
      final over = res['over_booked'] == true;
      _say(action == 'approve'
          ? '${r.person.name} is booked on ${r.workItem.ref}.${over ? ' They are over-booked, so the next planning cycle will move lower-priority work.' : ''}'
          : action == 'decline'
              ? 'Declined. ${r.requestedByName} has been told.'
              : 'Withdrawn.');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      // Inside the freeze horizon the server insists on a reason; ask again saying so.
      if (e.message.contains('freeze horizon') && action == 'approve') {
        final reason = await schReasonDialog(context,
            title: 'Approving inside the freeze horizon',
            message: e.message,
            confirmLabel: 'Approve with this reason');
        if (reason != null && reason.isNotEmpty && mounted) {
          await _post(action, r, {...body, 'reason': reason});
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
    if (_error != null) {
      return PageBody(child: ErrorState(title: 'Requests could not be loaded', message: _error, onRetry: _load));
    }
    final stacked = Breaks.isPhone(context);
    return PageBody(
      onRefresh: () => _load(silent: true),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PageHeader(
          title: 'Requests',
          subtitle: 'Asking for a named person, and the lead above them saying yes.',
          actions: [
            if (_pendingForMe > 0) InfoPill('$_pendingForMe awaiting your approval', icon: Icons.how_to_reg_outlined),
            if (_minePending > 0) InfoPill('$_minePending of yours pending', icon: Icons.schedule_outlined),
          ],
        ),
        if (_tabs.length > 1) ...[
          const SizedBox(height: Sp.lg),
          SegmentedTabs(
            labels: _tabs,
            selected: _tab,
            onChanged: (i) {
              setState(() => _tab = i);
              _load();
            },
          ),
        ],
        const SizedBox(height: Sp.lg),
        if (_requests.isEmpty)
          EmptyState(
            icon: Icons.how_to_reg_outlined,
            title: switch (_view) {
              'for_me' => 'Nothing is waiting on you',
              'mine' => 'You have not asked for anyone yet',
              _ => 'No requests have been raised',
            },
            message: switch (_view) {
              'for_me' => 'When somebody asks for a person in your part of the organisation, it lands here.',
              'mine' => 'Open a work item and use "Request a person" to ask for somebody\'s time.',
              _ => 'Requests raised anywhere in the workspace will appear here.',
            },
          )
        else
          for (final r in _requests)
            Padding(
              padding: const EdgeInsets.only(bottom: Sp.md),
              child: ReqRequestCard(
                request: r,
                stacked: stacked,
                onOpen: () => context.go(Routes.request(r.id)),
                onApprove: r.canApprove && !_busy ? () => _decide(r, 'approve') : null,
                onDecline: r.canApprove && !_busy ? () => _decide(r, 'decline') : null,
                onWithdraw: r.canWithdraw && !r.canApprove && !_busy ? () => _withdraw(r) : null,
              ),
            ),
      ]),
    );
  }
}
