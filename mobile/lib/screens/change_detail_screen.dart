import 'package:flutter/material.dart';

import '../widgets/states.dart';

/// Change — placeholder. Replace the body of [build]; the route in lib/router.dart
/// already points here.
class ChangeDetailScreen extends StatelessWidget {
  const ChangeDetailScreen({super.key, required this.id});

  /// Change proposal id (path parameter, as a string).
  final String id;

  @override
  Widget build(BuildContext context) {
    return const ComingSoon('Change');
  }
}
