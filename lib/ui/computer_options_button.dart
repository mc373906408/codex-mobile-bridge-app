import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../l10n/strings.dart';

enum _ComputerAction { rename }

class ComputerOptionsButton extends StatelessWidget {
  const ComputerOptionsButton({
    super.key,
    required this.name,
    required this.strings,
    required this.onRename,
  });

  final String name;
  final Strings strings;
  final VoidCallback? onRename;
  static const _touchTarget = 44.0;

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform == TargetPlatform.iOS) {
      return CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: const Size.square(_touchTarget),
        onPressed: onRename == null ? null : () => _showActions(context),
        child: Icon(
          CupertinoIcons.ellipsis_circle,
          semanticLabel: strings.t('Computer options'),
        ),
      );
    }
    return PopupMenuButton<_ComputerAction>(
      tooltip: strings.t('Computer options'),
      enabled: onRename != null,
      icon: const Icon(CupertinoIcons.ellipsis_circle),
      onSelected: (_) => onRename?.call(),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: _ComputerAction.rename,
          child: Text(strings.t('Rename computer')),
        ),
      ],
    );
  }

  Future<void> _showActions(BuildContext context) async {
    final action = await showCupertinoModalPopup<_ComputerAction>(
      context: context,
      semanticsDismissible: true,
      builder: (context) => CupertinoActionSheet(
        title: Text(name),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, _ComputerAction.rename),
            child: Text(strings.t('Rename computer')),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: Text(strings.t('Cancel')),
        ),
      ),
    );
    if (context.mounted && action == _ComputerAction.rename) onRename?.call();
  }
}
