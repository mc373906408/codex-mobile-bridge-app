import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/bridge_repository.dart';
import '../l10n/strings.dart';
import '../viewmodels/bridge_view_model.dart';
import '../viewmodels/cloud_view_model.dart';
import 'computer_options_button.dart';
import 'dialogs.dart';
import 'rename_computer_dialog.dart';

class CloudComputerCard extends StatelessWidget {
  const CloudComputerCard({
    super.key,
    required this.computer,
    required this.model,
    required this.cloud,
    required this.strings,
    required this.enabled,
    required this.onComputer,
  });

  final Computer computer;
  final BridgeViewModel model;
  final CloudViewModel? cloud;
  final Strings strings;
  final bool enabled;
  final ValueChanged<Computer> onComputer;

  bool get _relay => computer.connectionType == ConnectionType.relay;
  String get _status {
    if (_relay) {
      final online =
          cloud?.deviceState(computer)?.device.gateway.online == true;
      return online || cloud?.p2pConnected(computer) == true
          ? 'Online'
          : 'Offline';
    }
    return model.computer?.id == computer.id && model.authenticated
        ? 'Connected'
        : 'Not connected';
  }

  @override
  Widget build(BuildContext context) {
    final card = _card(context);
    if (_relay) return card;
    return Semantics(
      onDismiss: enabled
          ? () => removeComputerDialog(context, model, computer, strings)
          : null,
      child: Dismissible(
        key: ValueKey('remove-computer-${computer.id}'),
        direction: enabled
            ? DismissDirection.endToStart
            : DismissDirection.none,
        confirmDismiss: (_) async {
          await removeComputerDialog(context, model, computer, strings);
          return false;
        },
        background: _removeBackground(context),
        child: card,
      ),
    );
  }

  Widget _card(BuildContext context) {
    final rename = enabled && !model.renamingComputer
        ? () => renameComputerDialog(
            context,
            model: model,
            computer: computer,
            strings: strings,
          )
        : null;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(
          CupertinoIcons.desktopcomputer,
          color: Theme.of(context).colorScheme.primary,
        ),
        title: Text(
          model.computerName(computer),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        subtitle: Text(
          strings.t(_status),
          key: ValueKey('computer-status-${computer.id}'),
        ),
        trailing: ComputerOptionsButton(
          key: ValueKey('computer-options-${computer.id}'),
          name: model.computerName(computer),
          strings: strings,
          onRename: rename,
        ),
        onLongPress: rename,
        onTap: enabled ? () => onComputer(computer) : null,
      ),
    );
  }

  Widget _removeBackground(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.all(4),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.delete_outline, color: colors.onErrorContainer),
          const SizedBox(width: 8),
          Text(
            strings.t('Remove'),
            style: TextStyle(color: colors.onErrorContainer),
          ),
        ],
      ),
    );
  }
}
