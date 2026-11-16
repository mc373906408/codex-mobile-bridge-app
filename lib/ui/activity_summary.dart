import 'package:flutter/material.dart';

import '../data/bridge_repository.dart';
import 'business/appearance_settings.dart';
import 'business/common.dart';

enum WorkActivityKind { reasoning, command, files, tool }

WorkActivityKind workActivityKind(ChatMessage message) {
  final data = jsonObject(message.metadata);
  final kind = textValue(data['kind']).toLowerCase();
  if (message.role == 'reasoning' ||
      kind == 'reasoning' ||
      message.title == '思考摘要') {
    return WorkActivityKind.reasoning;
  }
  if (data['fileSummary'] is Map ||
      const {'filechange', 'filechanges'}.contains(kind) ||
      data['changeType'] != null) {
    return WorkActivityKind.files;
  }
  final tool = textValue(data['tool']).toLowerCase();
  if (kind == 'commandexecution' ||
      const {'bash', 'shell', 'exec_command', 'run_command'}.contains(tool) ||
      const {'执行命令', 'exec_command', 'Run command'}.contains(message.title)) {
    return WorkActivityKind.command;
  }
  return WorkActivityKind.tool;
}

IconData workActivityIcon(WorkActivityKind kind) => switch (kind) {
  WorkActivityKind.reasoning => Icons.auto_awesome_outlined,
  WorkActivityKind.command => Icons.terminal_outlined,
  WorkActivityKind.files => Icons.edit_outlined,
  WorkActivityKind.tool => Icons.build_outlined,
};

bool isWorkActivity(ChatMessage message) =>
    !const {'assistant', 'user', 'error'}.contains(message.role);

class ReconnectStatus {
  const ReconnectStatus(this.attempt, this.total);
  final int attempt, total;

  bool continues(ReconnectStatus previous) =>
      total == previous.total && attempt >= previous.attempt;
}

final _reconnectText = RegExp(
  r'^(?:Reconnecting(?:\.{3}|…)?|正在重新连接(?:\.{3}|…)?)[ \t]+([0-9]+)[ \t]*/[ \t]*([0-9]+)$',
  caseSensitive: false,
);

/// Native retry notices can arrive as assistant or error records. Recognize only
/// a complete status line so quoted examples and actual failures stay intact.
ReconnectStatus? reconnectStatus(ChatMessage message) {
  if (!const {'assistant', 'error'}.contains(message.role) ||
      message.truncated ||
      message.output.isNotEmpty ||
      message.attachments.isNotEmpty) {
    return null;
  }
  final match = _reconnectText.firstMatch(message.text.trim());
  if (match == null) return null;
  final attempt = int.tryParse(match[1]!), total = int.tryParse(match[2]!);
  if (attempt == null || total == null || attempt < 1 || attempt > total) {
    return null;
  }
  return ReconnectStatus(attempt, total);
}

enum TranscriptRowKind { message, activity, reconnect }

class TranscriptRow {
  TranscriptRow(
    this.messages, {
    required this.kind,
    required this.turnId,
    this.reconnect,
  });
  final List<ChatMessage> messages;
  final TranscriptRowKind kind;
  String turnId;
  ReconnectStatus? reconnect;
  bool get activity => kind == TranscriptRowKind.activity;

  bool belongsToRunningTurn(SessionSnapshot snapshot) {
    final metadata = jsonObject(snapshot.metadata);
    final state = jsonObject(metadata['session'] ?? metadata);
    final activeTurn = textValue(state['activeTurnId'] ?? state['turnId']);
    if (turnId.isNotEmpty && activeTurn.isNotEmpty && turnId != activeTurn) {
      return false;
    }
    return !const {
      'completed',
      'failed',
      'interrupted',
      'cancelled',
    }.contains(jsonObject(messages.last.metadata)['turnStatus']);
  }
}

/// Group presentation only: message IDs, detail reads and action targets stay
/// unchanged. An answer, actual failure or different turn separates activities.
/// Retry notices are separate, merging consecutive attempts even when the native
/// retry starts a new turn; their current activity identity follows the latest.
List<TranscriptRow> groupTranscriptRows(
  List<ChatMessage> messages,
  ChatAppearance appearance,
) {
  final rows = <TranscriptRow>[];
  TranscriptRow? group;
  for (final message in messages) {
    final metadata = jsonObject(message.metadata);
    final reconnect = reconnectStatus(message);
    final kind = reconnect != null
        ? TranscriptRowKind.reconnect
        : isWorkActivity(message)
        ? TranscriptRowKind.activity
        : TranscriptRowKind.message;
    final turn = textValue(metadata['turnId']);
    final sameReconnectRun =
        reconnect != null &&
        group?.kind == TranscriptRowKind.reconnect &&
        group?.reconnect != null &&
        reconnect.continues(group!.reconnect!);
    if (kind == TranscriptRowKind.message ||
        group?.kind != kind ||
        (kind == TranscriptRowKind.activity && group?.turnId != turn) ||
        (kind == TranscriptRowKind.reconnect && !sameReconnectRun)) {
      group = null;
    }
    if (!appearance.visible(message.role, metadata)) continue;
    if (group != null) {
      group.messages.add(message);
      group.reconnect = reconnect;
      if (reconnect != null) group.turnId = turn;
    } else {
      final row = TranscriptRow(
        [message],
        kind: kind,
        turnId: turn,
        reconnect: reconnect,
      );
      rows.add(row);
      group = kind == TranscriptRowKind.message ? null : row;
    }
  }
  return rows;
}

class ReconnectStatusRow extends StatelessWidget {
  const ReconnectStatusRow({
    super.key,
    required this.status,
    required this.running,
  });
  final ReconnectStatus status;
  final bool running;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: running,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: WorkActivityLabel(
        icon: Icons.wifi_rounded,
        running: running,
        label:
            '${words(context, '正在重新连接', 'Reconnecting')} ${status.attempt}/${status.total}',
      ),
    ),
  );
}

String activityDetailLabel(BuildContext context, ChatMessage message) {
  final data = jsonObject(message.metadata);
  final kind = workActivityKind(message);
  final running = const {
    'running',
    'active',
    'inProgress',
  }.contains(data['status']);
  if (kind == WorkActivityKind.command) {
    final command = textValue(data['command']).isNotEmpty
        ? textValue(data['command'])
        : message.text.split('\n').first.trim();
    return [
      words(context, running ? '正在运行' : '已运行', running ? 'Running' : 'Ran'),
      if (command.isNotEmpty) command,
    ].join(' ');
  }
  if (kind == WorkActivityKind.reasoning) {
    return words(context, '思考摘要', 'Thinking summary');
  }
  return message.title.isNotEmpty
      ? message.title
      : words(context, '工具调用', 'Tool call');
}

class ActivitySummary extends StatelessWidget {
  const ActivitySummary({
    super.key,
    required this.messages,
    required this.running,
    required this.expanded,
    required this.onToggle,
    required this.detailsBuilder,
  });
  final List<ChatMessage> messages;
  final bool running, expanded;
  final VoidCallback onToggle;
  final WidgetBuilder detailsBuilder;

  @override
  Widget build(BuildContext context) {
    final kinds = messages.map(workActivityKind).toSet();
    final kind = kinds.contains(WorkActivityKind.files)
        ? WorkActivityKind.files
        : kinds.contains(WorkActivityKind.command)
        ? WorkActivityKind.command
        : kinds.first;
    final labels = <String>[
      if (kinds.contains(WorkActivityKind.files))
        words(context, '编辑了文件', 'Edited files'),
      if (kinds.contains(WorkActivityKind.command))
        words(context, '运行了命令', 'Ran commands'),
      if (kinds.contains(WorkActivityKind.tool))
        words(context, '调用了工具', 'Used tools'),
    ];
    final label = running
        ? words(context, '正在思考与处理…', 'Thinking and working…')
        : labels.isEmpty
        ? words(context, '思考摘要', 'Thinking summary')
        : labels.join(' · ');
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: expanded,
            child: InkWell(
              onTap: onToggle,
              borderRadius: BorderRadius.circular(6),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 40),
                child: Row(
                  children: [
                    Flexible(
                      child: WorkActivityLabel(
                        label: label,
                        icon: workActivityIcon(kind),
                        running: running,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 17,
                      color: colors.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded) detailsBuilder(context),
        ],
      ),
    );
  }
}

/// The repeating animation is local to the label. It stops when execution,
/// foreground visibility or accessibility motion settings no longer allow it.
class WorkActivityLabel extends StatefulWidget {
  const WorkActivityLabel({
    super.key,
    required this.label,
    required this.running,
    this.icon = Icons.auto_awesome_outlined,
  });
  final String label;
  final bool running;
  final IconData icon;
  @override
  State<WorkActivityLabel> createState() => _WorkActivityLabelState();
}

class _WorkActivityLabelState extends State<WorkActivityLabel>
    with SingleTickerProviderStateMixin {
  late final pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
    value: 1,
  );
  bool allowMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    allowMotion =
        TickerMode.valuesOf(context).enabled &&
        Visibility.of(context) &&
        !MediaQuery.disableAnimationsOf(context) &&
        !MediaQuery.accessibleNavigationOf(context);
    syncAnimation();
  }

  @override
  void didUpdateWidget(WorkActivityLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    syncAnimation();
  }

  void syncAnimation() {
    if (widget.running && allowMotion) {
      if (!pulse.isAnimating) pulse.repeat(reverse: true);
    } else {
      pulse.stop();
      pulse.value = 1;
    }
  }

  @override
  void dispose() {
    pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: pulse,
      builder: (_, child) => Opacity(
        opacity: .65 + .35 * Curves.easeInOut.transform(pulse.value),
        child: child,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(widget.icon, size: 17, color: colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
