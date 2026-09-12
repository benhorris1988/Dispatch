import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../shell/app_shell.dart';
import '../shell/nav.dart';
import '../widgets/widgets.dart';
import 'parts/add_work_form.dart';

/// Add work (mobile-add-work). The form itself lives in
/// [AddWorkForm] so the Pipeline can open the same thing in a dialog.
class AddWorkScreen extends StatelessWidget {
  const AddWorkScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final workspace = context.watch<WorkspaceConfig>().workspace?.name;

    return PageBody(
      maxWidth: 760,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(
          title: 'Add work',
          subtitle: workspace == null ? 'New item for the pipeline' : '$workspace pipeline',
        ),
        AddWorkForm(
          onCreated: (ref) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$ref added to the pipeline.')));
            context.go(Routes.item(ref));
          },
          onCancel: () => context.canPop() ? context.pop() : context.go(Routes.pipeline),
        ),
      ]),
    );
  }
}
