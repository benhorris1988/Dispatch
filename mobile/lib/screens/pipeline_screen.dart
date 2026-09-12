import 'package:flutter/material.dart';

import '../widgets/states.dart';

/// Pipeline — placeholder. Replace the body of [build]; the route in lib/router.dart
/// already points here.
class PipelineScreen extends StatelessWidget {
  const PipelineScreen({super.key, this.query});

  /// Optional search text from the shell search field (?q=).
  final String? query;

  @override
  Widget build(BuildContext context) {
    return const ComingSoon('Pipeline');
  }
}
