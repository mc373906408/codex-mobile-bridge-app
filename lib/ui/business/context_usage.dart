import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import '../design/bridge_theme.dart';
import 'common.dart';

String _usageTitle(BuildContext context) =>
    words(context, '上下文用量', 'Context usage');

Future<bool> confirmContextCompaction(BuildContext context) => confirmAction(
  context,
  words(context, '压缩上下文？', 'Compact context?'),
  words(
    context,
    '由当前客户端压缩此聊天的上下文。',
    'Ask the current client to compact this conversation.',
  ),
);

Future<void> contextUsageDialog(BuildContext context, SessionBusiness scope) =>
    showDialog<void>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (_) => _ContextUsageDialog(scope: scope),
    );

class _ContextUsageDialog extends StatefulWidget {
  const _ContextUsageDialog({required this.scope});

  final SessionBusiness scope;

  @override
  State<_ContextUsageDialog> createState() => _ContextUsageDialogState();
}

class _ContextUsageDialogState extends State<_ContextUsageDialog> {
  bool _submitting = false, _submitted = false;
  Object? _error;
  SessionBusiness get scope => widget.scope;

  SessionSnapshot? get _current {
    final current = scope.model.snapshot;
    return scope.current &&
            scope.model.selected == scope.session &&
            current?.session == scope.session &&
            current?.accountIdentity == scope.snapshot.accountIdentity &&
            scope.snapshot.accountIdentity.isNotEmpty
        ? current
        : null;
  }

  Json _state(Json metadata) =>
      metadata['session'] is Map ? jsonObject(metadata['session']) : metadata;

  String? _unavailable(BuildContext context, SessionSnapshot? current) {
    if (current == null) {
      return words(
        context,
        '会话状态已变更，请重新打开。',
        'The chat changed. Reopen this panel.',
      );
    }
    if (!scope.model.fresh || !current.connected) {
      return words(
        context,
        '连接原会话后可压缩。',
        'Connect this chat before compacting.',
      );
    }
    if (scope.model.pending.any((operation) => operation.action == 'compact')) {
      return words(
        context,
        '请先在电脑上核对上次压缩。',
        'Check the previous compaction on your computer.',
      );
    }
    final metadata = jsonObject(current.metadata);
    final state = _state(metadata);
    if (scope.model.busy ||
        current.running ||
        current.approvals.isNotEmpty ||
        jsonRows(state['requests']).isNotEmpty) {
      return words(context, '会话空闲后可压缩。', 'Wait for this chat to become idle.');
    }
    if (current.status != 'idle') {
      return words(context, '尚未确认会话空闲。', 'The chat is not confirmed idle.');
    }
    final capabilities = jsonObject(
      metadata['capabilities'] is Map
          ? metadata['capabilities']
          : state['capabilities'],
    );
    if (capabilities['compact'] != true) {
      return words(
        context,
        '当前会话暂不支持手动压缩。',
        'Manual compaction is unavailable for this chat.',
      );
    }
    return null;
  }

  Future<void> _compact() async {
    if (_submitting ||
        _submitted ||
        _error != null ||
        _unavailable(context, _current) != null) {
      return;
    }
    setState(() => _submitting = true);
    try {
      if (!await confirmContextCompaction(context) || !mounted) return;
      final current = _current;
      if (current == null || _unavailable(context, current) != null) return;
      scope.snapshot = current;
      await scope.write(SessionCommand.compact, const {});
      if (mounted) setState(() => _submitted = true);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: scope.model,
    builder: (context, _) {
      final current = _current;
      final theme = Theme.of(context), colors = theme.colorScheme;
      final unavailable = _unavailable(context, current);
      final status = current == null
          ? unavailable
          : _submitting
          ? null
          : _error != null
          ? businessError(context, _error)
          : _submitted
          ? words(context, '压缩请求已提交。', 'Compaction requested.')
          : unavailable;
      final details = _ContextUsageDetails(
        state: {
          ..._state(jsonObject(current?.metadata)),
          if (!scope.model.fresh || current?.connected == false)
            'connected': false,
        },
      );
      final actions = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed:
                _submitting ||
                    _submitted ||
                    _error != null ||
                    unavailable != null
                ? null
                : _compact,
            icon: Icon(
              _submitting
                  ? Icons.hourglass_top_rounded
                  : Icons.compress_rounded,
            ),
            label: Text(
              _submitting
                  ? words(context, '正在提交…', 'Submitting…')
                  : words(context, '压缩上下文', 'Compact context'),
              textAlign: TextAlign.center,
            ),
          ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  status,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _error != null && current != null
                        ? colors.error
                        : colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      );
      return PopScope(
        canPop: !_submitting,
        child: Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 20,
          ),
          constraints: const BoxConstraints(maxWidth: 380),
          child: BridgeGlass(
            style: BridgeGlassStyle.regular,
            radius: 20,
            padding: const EdgeInsets.fromLTRB(20, 12, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _usageTitle(context),
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: words(context, '关闭', 'Close'),
                      onPressed: _submitting
                          ? null
                          : () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                Flexible(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final scrollActions = constraints.maxHeight < 240;
                      return Padding(
                        padding: const EdgeInsets.only(top: 8, right: 4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Flexible(
                              child: SingleChildScrollView(
                                child: scrollActions
                                    ? Column(children: [details, actions])
                                    : details,
                              ),
                            ),
                            if (!scrollActions) actions,
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class ContextUsageCard extends StatelessWidget {
  const ContextUsageCard({super.key, required this.state});
  final Json state;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _usageTitle(context),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          _ContextUsageDetails(state: state),
        ],
      ),
    ),
  );
}

class _ContextUsageDetails extends StatelessWidget {
  const _ContextUsageDetails({required this.state});

  final Json state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final caption = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final usage = jsonObject(state['contextUsage']);
    final previous = jsonObject(state['lastPromptContextUsage']);
    final value = usage.isEmpty ? previous : usage;
    if (value.isEmpty) {
      return Text(
        words(
          context,
          '当前客户端尚未提供此会话的上下文用量。',
          'The client has not supplied context usage for this chat.',
        ),
        style: caption,
      );
    }
    final used = value['usedTokens'], capacity = value['contextWindow'];
    final lastPrompt = usage.isEmpty || value['measurement'] == 'lastPrompt';
    final ratio =
        !lastPrompt &&
            used is num &&
            used.isFinite &&
            used >= 0 &&
            capacity is num &&
            capacity.isFinite &&
            capacity > 0
        ? used / capacity
        : null;
    String number(Object? value) => value is num && value.isFinite && value >= 0
        ? value.round().toString().replaceAllMapped(
            RegExp(r'(\d)(?=(\d{3})+$)'),
            (match) => '${match[1]},',
          )
        : words(context, '暂未提供', 'Unavailable');
    Widget line(String zh, String en, Object? amount) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(words(context, zh, en), style: caption)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              number(amount),
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    final cache = jsonObject(value['cache']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (ratio != null) ...[
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${(ratio * 100).toStringAsFixed(1)}%',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
              Text(words(context, '已使用', 'used'), style: caption),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: ratio.clamp(0, 1),
            minHeight: 6,
            borderRadius: const BorderRadius.all(Radius.circular(4)),
          ),
          const SizedBox(height: 12),
        ],
        line(
          lastPrompt ? '最近一次模型输入' : '已用 Token',
          lastPrompt ? 'Last model input' : 'Tokens used',
          used,
        ),
        line('上下文容量', 'Context capacity', capacity),
        if (value['model'] != null)
          Text(textValue(value['model']), style: caption),
        if (value['autoCompactThresholdTokens'] is num)
          line(
            '自动压缩阈值',
            'Auto-compaction threshold',
            value['autoCompactThresholdTokens'],
          ),
        if (value['pressureTokens'] is num && value['pressureTokens'] != used)
          line(
            '已确认上下文 Token',
            'Confirmed context tokens',
            value['pressureTokens'],
          ),
        for (final item in const {
          'inputTokens': ['最近输入 Token', 'Recent input tokens'],
          'cacheReadTokens': ['缓存读取 Token', 'Cache read tokens'],
          'cacheWriteTokens': ['缓存写入 Token', 'Cache write tokens'],
        }.entries)
          if (cache[item.key] is num)
            line(item.value[0], item.value[1], cache[item.key]),
        if (lastPrompt)
          Text(
            words(
              context,
              '统计最近一次请求的输入与缓存 Token，不包含尚未发送的内容。',
              'Counts input and cached tokens in the latest request; unsent content is excluded.',
            ),
            style: caption,
          ),
        if (value['compacted'] == true)
          Text(
            words(
              context,
              '最近一次压缩后统计。',
              'Measured after the latest compaction.',
            ),
            style: caption,
          ),
        if (value['estimated'] == true)
          Text(
            words(
              context,
              '包含客户端对尚未发送内容的估算。',
              'Includes the client’s estimate of unsent content.',
            ),
            style: caption,
          ),
        if (value['cached'] == true || state['connected'] == false)
          Text(
            words(
              context,
              '当前为缓存数据，连接恢复后更新。',
              'Cached data; updates when the connection recovers.',
            ),
            style: caption,
          ),
      ],
    );
  }
}
