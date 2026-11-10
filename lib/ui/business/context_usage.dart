import 'package:flutter/material.dart';

import 'common.dart';

class ContextUsageCard extends StatelessWidget {
  const ContextUsageCard({super.key, required this.state});
  final Json state;

  @override
  Widget build(BuildContext context) {
    final usage = jsonObject(state['contextUsage']);
    final previous = jsonObject(state['lastPromptContextUsage']);
    final value = usage.isEmpty ? previous : usage;
    final used = value['usedTokens'], capacity = value['contextWindow'];
    final lastPrompt = usage.isEmpty || value['measurement'] == 'lastPrompt';
    final ratio =
        !lastPrompt &&
            used is num &&
            used >= 0 &&
            capacity is num &&
            capacity > 0
        ? used / capacity
        : null;
    String number(Object? value) => value is num && value.isFinite && value >= 0
        ? value.round().toString().replaceAllMapped(
            RegExp(r'(\d)(?=(\d{3})+$)'),
            (m) => '${m[1]},',
          )
        : words(context, '暂未提供', 'Unavailable');
    Widget line(String zh, String en, Object? amount) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text('${words(context, zh, en)} · ${number(amount)}'),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              words(context, '上下文用量', 'Context usage'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (value.isEmpty)
              Text(
                words(
                  context,
                  '当前客户端尚未提供此会话的上下文用量。',
                  'The client has not supplied context usage for this chat.',
                ),
              ),
            if (value.isNotEmpty) ...[
              line(
                lastPrompt ? '最近一次模型输入' : '已用 Token',
                lastPrompt ? 'Last model input' : 'Tokens used',
                used,
              ),
              line('上下文容量', 'Context capacity', capacity),
              if (ratio != null) ...[
                LinearProgressIndicator(value: ratio.clamp(0, 1)),
                Text('${(ratio * 100).toStringAsFixed(1)}%'),
              ],
              if (value['model'] != null) Text(textValue(value['model'])),
              if (value['autoCompactThresholdTokens'] is num)
                line(
                  '自动压缩阈值',
                  'Auto-compaction threshold',
                  value['autoCompactThresholdTokens'],
                ),
              if (value['pressureTokens'] is num &&
                  value['pressureTokens'] != used)
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
                if (jsonObject(value['cache'])[item.key] is num)
                  line(
                    item.value[0],
                    item.value[1],
                    jsonObject(value['cache'])[item.key],
                  ),
              if (lastPrompt)
                Text(
                  words(
                    context,
                    '统计最近一次请求的输入与缓存 Token，不包含尚未发送的内容。',
                    'Counts input and cached tokens in the latest request; unsent content is excluded.',
                  ),
                ),
              if (value['compacted'] == true)
                Text(
                  words(
                    context,
                    '最近一次压缩后统计。',
                    'Measured after the latest compaction.',
                  ),
                ),
              if (value['estimated'] == true)
                Text(
                  words(
                    context,
                    '包含客户端对尚未发送内容的估算。',
                    'Includes the client’s estimate of unsent content.',
                  ),
                ),
              if (value['cached'] == true || state['connected'] == false)
                Text(
                  words(
                    context,
                    '当前为缓存数据，连接恢复后更新。',
                    'Cached data; updates when the connection recovers.',
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
