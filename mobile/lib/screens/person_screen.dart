import 'package:flutter/material.dart';

import '../widgets/states.dart';

/// Person — placeholder. Replace the body of [build]; the route in lib/router.dart
/// already points here.
class PersonScreen extends StatelessWidget {
  const PersonScreen({super.key, required this.id});

  /// Person id (path parameter, as a string).
  final String id;

  @override
  Widget build(BuildContext context) {
    return const ComingSoon('Person');
  }
}
