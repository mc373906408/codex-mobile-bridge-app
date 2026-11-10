import 'package:flutter/material.dart';

import 'common.dart';

class AccountDetails extends StatelessWidget {
  const AccountDetails({super.key, required this.row});
  final Json row;
  @override
  Widget build(BuildContext context) {
    final details = jsonObject(row['details']);
    final usage = jsonObject(details['usage'] ?? row['usage'] ?? row['quota']);
    final models = jsonObject(details['models']);
    String date(Object? seconds) => seconds is num
        ? DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round())
              .toLocal()
              .toString()
        : textValue(seconds);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (usage['status'] == 'loading' || models['status'] == 'loading')
          const LinearProgressIndicator(),
        if (usage['error'] != null) SelectableText(textValue(usage['error'])),
        for (final bucket in jsonRows(usage['limits'])) ...[
          for (final window in jsonRows(bucket['windows']))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${bucket['name'] ?? ''} · ${window['windowDurationMins'] ?? ''} ${words(context, '分钟', 'minutes')}',
                  ),
                  Text(
                    window['remainingPercent'] is num
                        ? '${words(context, '剩余', 'Remaining')} ${(window['remainingPercent'] as num).toStringAsFixed(1)}%'
                        : '${window['remaining'] ?? '—'} / ${window['total'] ?? '—'} ${window['unit'] ?? ''}',
                  ),
                  if (window['remainingPercent'] is num)
                    LinearProgressIndicator(
                      value:
                          ((window['remainingPercent'] as num).toDouble() / 100)
                              .clamp(0, 1),
                    ),
                  if (window['resetsAt'] != null)
                    Text(
                      '${words(context, '恢复时间', 'Resets')}: ${date(window['resetsAt'])}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          if (bucket['credits'] is Map)
            Text(
              'Credits: ${jsonObject(bucket['credits'])['unlimited'] == true ? '∞' : jsonObject(bucket['credits'])['balance'] ?? '—'}',
            ),
        ],
        for (final wallet in jsonRows(jsonObject(usage['balance'])['wallets']))
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              '${words(context, '余额', 'Balance')}: ${wallet['currency'] ?? ''} ${wallet['remaining'] ?? '—'}',
            ),
            subtitle: Text(
              '${words(context, '充值 / 赠送', 'Paid / granted')}: ${wallet['toppedUp'] ?? '—'} / ${wallet['granted'] ?? '—'}',
            ),
          ),
        if (usage['checkedAt'] != null)
          Text(
            '${words(context, '检查时间', 'Checked')}: ${date(usage['checkedAt'])}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (jsonObject(usage['subscription'])['periodEndsAt'] != null)
          Text(
            '${words(context, '订阅周期截止', 'Subscription period ends')}: ${date(jsonObject(usage['subscription'])['periodEndsAt'])}',
          ),
        if (models['error'] != null) Text(textValue(models['error'])),
        for (final model in jsonRows(models['models']))
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(textValue(model['name'] ?? model['id'])),
            subtitle: Text(
              '${model['id']}\n${(model['efforts'] as List? ?? []).join(' / ')}',
            ),
          ),
      ],
    );
  }
}
