import 'package:flutter/material.dart';

import '../widgets/states.dart';

/// Work item — placeholder. Replace the body of [build]; the route in lib/router.dart
/// already points here.
class WorkItemScreen extends StatelessWidget {
  const WorkItemScreen({super.key, required this.ref});

  /// Work item reference, e.g. WI-1042.
  final String ref;

  @override
  Widget build(BuildContext context) {
    return const ComingSoon('Work item');
  }
}
