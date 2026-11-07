import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import '../session_environment.dart';

class SessionListTile extends StatelessWidget {
  const SessionListTile({
    super.key,
    required this.row,
    required this.computerName,
    required this.selected,
    required this.onTap,
  });

  final SessionSummary row;
  final String computerName;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: ListTile(
        selected: selected,
        tileColor: colors.surface,
        selectedTileColor: colors.primaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        title: Text(
          row.title.isEmpty ? row.session.id : row.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        subtitle: _subtitle(),
        trailing: Icon(
          CupertinoIcons.chevron_forward,
          color: selected ? colors.primary : colors.outline,
          size: 18,
        ),
        onTap: onTap,
      ),
    );
  }

  Widget _subtitle() {
    final environment = sessionEnvironmentName(
      row.session.environment,
      computerName: computerName,
      label: row.environmentLabel,
    );
    final project = row.cwd
        .split(RegExp(r'[/\\]'))
        .where((part) => part.isNotEmpty)
        .lastOrNull;
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Text(
        [environment, ?project].join('  /  '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
    );
  }
}
