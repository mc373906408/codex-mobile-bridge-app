import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import '../../data/session_activity.dart';
import '../../l10n/strings.dart';
import '../session_environment.dart';

class SessionListTile extends StatelessWidget {
  const SessionListTile({
    super.key,
    required this.row,
    required this.computerName,
    required this.selected,
    required this.onTap,
    this.onMenu,
    this.read = false,
    this.activity,
    this.messageTime,
    this.updateTime,
  });

  final SessionSummary row;
  final String computerName;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onMenu;
  final bool read;
  final SessionActivityKind? activity;
  final DateTime? messageTime;
  final DateTime? updateTime;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: ListTile(
        minTileHeight: 60,
        minVerticalPadding: 6,
        selected: selected,
        tileColor: colors.surface,
        selectedTileColor: colors.primaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        title: Row(
          children: [
            if (activity != null) ...[
              _activityDot(context),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                row.title.isEmpty ? row.session.id : row.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: read ? FontWeight.w400 : FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        subtitle: _subtitle(context),
        leading: row.pinned
            ? const Icon(Icons.push_pin_outlined, size: 16)
            : null,
        onTap: onTap,
        onLongPress: onMenu,
      ),
    );
  }

  Widget _activityDot(BuildContext context) {
    final (color, label) = switch (activity!) {
      SessionActivityKind.running => (const Color(0xff16a34a), 'Running'),
      SessionActivityKind.completed => (
        const Color(0xff3b82f6),
        'Completed, unread',
      ),
      SessionActivityKind.failed => (const Color(0xffd97706), 'Failed, unread'),
      SessionActivityKind.interrupted => (
        const Color(0xffd97706),
        'Stopped, unread',
      ),
      SessionActivityKind.awaiting => (
        const Color(0xffd97706),
        'Awaiting your response',
      ),
      SessionActivityKind.unknown => (
        const Color(0xff94a3b8),
        'Task status unavailable',
      ),
    };
    final text = Strings(Localizations.localeOf(context)).t(label);
    return Tooltip(
      message: text,
      child: Semantics(
        label: text,
        child: Container(
          key: ValueKey(('session-activity', row.session)),
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }

  Widget _subtitle(BuildContext context) {
    final environment = sessionEnvironmentName(
      row.session.environment,
      computerName: computerName,
      label: row.environmentLabel,
    );
    final project = row.cwd
        .split(RegExp(r'[/\\]'))
        .where((part) => part.isNotEmpty)
        .lastOrNull;
    const style = TextStyle(fontSize: 11);
    final location = Text(
      [environment, ?project].join('  /  '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    final time = messageTime ?? updateTime;
    if (time == null) {
      return Padding(padding: const EdgeInsets.only(top: 5), child: location);
    }
    final local = time.toLocal();
    final localizations = MaterialLocalizations.of(context);
    final strings = Strings(Localizations.localeOf(context));
    final clock = localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(local),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    final day = localizations.formatCompactDate(local);
    final short = DateUtils.isSameDay(local, DateTime.now())
        ? clock
        : messageTime == null
        ? day
        : '$day $clock';
    final prefix = strings.t(messageTime == null ? 'Updated' : 'Last message');
    final timestamp = Tooltip(
      message: '$prefix: ${localizations.formatCompactDate(local)} $clock',
      child: Text(
        short,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (MediaQuery.textScalerOf(context).scale(11) >= 17) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [location, timestamp],
            );
          }
          return Row(
            children: [
              Flexible(child: location),
              const SizedBox(width: 10),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * .62,
                ),
                child: timestamp,
              ),
            ],
          );
        },
      ),
    );
  }
}
