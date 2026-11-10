import 'dart:convert';

import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import 'common.dart';

Future<void> reviewApproval(
  BuildContext context,
  BridgeViewModel model,
  SessionSnapshot snapshot,
  ApprovalRequest request,
) => Navigator.push(
  context,
  MaterialPageRoute<void>(
    builder: (_) =>
        ApprovalPage(model: model, snapshot: snapshot, request: request),
  ),
);

class ApprovalPage extends StatefulWidget {
  const ApprovalPage({
    super.key,
    required this.model,
    required this.snapshot,
    required this.request,
  });
  final BridgeViewModel model;
  final SessionSnapshot snapshot;
  final ApprovalRequest request;
  @override
  State<ApprovalPage> createState() => _ApprovalState();
}

class _ApprovalState extends State<ApprovalPage> {
  final Map<String, TextEditingController> inputs = {};
  final Map<String, Set<String>> selections = {};
  final Json mcp = {};
  final feedback = TextEditingController();
  bool busy = false;
  Object? error;
  late ApprovalRequest request = widget.request;
  late final scope = SessionBusiness(widget.model, widget.snapshot);
  Json get raw => jsonObject(request.metadata);
  bool get codex => scope.session.provider == Provider.codex;
  Json get params => jsonObject(codex ? raw['params'] : raw['input']);
  String get method => textValue(raw['method']);
  List<Json> get questions => jsonRows(params['questions']);
  @override
  void dispose() {
    scope.dispose();
    for (final c in inputs.values) {
      c.dispose();
    }
    feedback.dispose();
    super.dispose();
  }

  Future<void> submit(Json response, {bool topLevel = false}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await scope.write(SessionCommand.respond, {
        'requestId': jsonDecode(request.wireId),
        'expectedRequestFingerprint': request.fingerprint,
        ...(codex && !topLevel ? {'response': response} : response),
      });
      if (response['action'] == 'skip' && result['status'] != 'skipped') {
        throw StateError(
          'Skip result is unconfirmed; refresh the request before continuing',
        );
      }
      if (widget.model.selected == scope.session) {
        await widget.model.openSession(scope.session);
      }
      final remaining = scope.snapshot.approvals
          .where((r) => r.wireId == request.wireId)
          .firstOrNull;
      if (mounted && response['action'] == 'skip' && remaining != null) {
        setState(() => request = remaining);
      } else if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String questionKey(Json q, int i) => textValue(q['id'] ?? q['question'] ?? i);
  void answers() {
    final Json values = {};
    for (var i = 0; i < questions.length; i++) {
      final key = questionKey(questions[i], i),
          text = inputs[key]?.text.trim() ?? '';
      final answers = [...?selections[key], if (text.isNotEmpty) text];
      if (answers.isEmpty) {
        setState(
          () => error = words(context, '请回答每一项问题', 'Answer every question'),
        );
        return;
      }
      values[key] = codex ? answers : {'answers': answers};
    }
    submit({'answers': values, if (!codex) 'decision': 'accept'});
  }

  void acceptMcp() {
    final schema = jsonObject(params['requestedSchema']);
    final content = <String, dynamic>{...mcp};
    for (final entry in jsonObject(schema['properties']).entries) {
      final field = jsonObject(entry.value), key = entry.key;
      if (field['enum'] is List || field['type'] == 'boolean') continue;
      final text = inputs[key]?.text ?? '';
      if (text.isEmpty) continue;
      if (field['type'] == 'integer' || field['type'] == 'number') {
        final number = field['type'] == 'integer'
            ? int.tryParse(text)
            : num.tryParse(text);
        if (number == null) {
          setState(
            () => error =
                '${words(context, '请输入有效数字', 'Enter a valid number')}: $key',
          );
          return;
        }
        content[key] = number;
      } else {
        content[key] = text;
      }
    }
    for (final key in schema['required'] as List? ?? []) {
      if (!content.containsKey(key) || content[key] == '') {
        setState(
          () => error =
              '${words(context, '请填写必填项', 'Complete the required field')}: $key',
        );
        return;
      }
    }
    submit({'action': 'accept', 'content': content});
  }

  Widget button(String zh, String en, Json response) => Padding(
    padding: const EdgeInsets.only(right: 8, bottom: 8),
    child: OutlinedButton(
      onPressed: busy ? null : () => submit(response),
      child: Text(words(context, zh, en)),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final computer = jsonObject(params['computerUse']);
    final isInput = questions.isNotEmpty;
    final isMcp = method == 'mcpServer/elicitation/request',
        isPlan = method == 'item/plan/requestImplementation';
    final detail = codex ? params : raw['input'] ?? raw;
    return Scaffold(
      appBar: AppBar(title: Text(words(context, '审核请求', 'Review request'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(request.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          SelectableText(const JsonEncoder.withIndent('  ').convert(detail)),
          const SizedBox(height: 16),
          if (error != null)
            SelectableText(
              businessError(context, error),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (busy) const LinearProgressIndicator(),
          if (!request.supported)
            Text(
              words(
                context,
                '当前客户端要求在电脑处理此请求。',
                'The current client requires handling this request on the computer.',
              ),
            )
          else if (raw['decisions'] is List)
            Wrap(
              children: [
                for (final decision in jsonRows(raw['decisions']))
                  button(
                    textValue(decision['label']),
                    textValue(decision['label']),
                    {'decision': decision['id']},
                  ),
              ],
            )
          else if (isPlan) ...[
            TextField(
              controller: feedback,
              onChanged: (_) => setState(() {}),
              minLines: 3,
              maxLines: 8,
              maxLength: 20000,
              decoration: InputDecoration(
                labelText: words(
                  context,
                  '修改意见（可选）',
                  'Revision notes (optional)',
                ),
              ),
            ),
            OutlinedButton(
              onPressed: busy || feedback.text.trim().isNotEmpty
                  ? null
                  : () => submit({'action': 'implement'}),
              child: Text(words(context, '按照当前规划结果执行', 'Implement the plan')),
            ),
            OutlinedButton(
              onPressed: busy
                  ? null
                  : () {
                      if (feedback.text.trim().isEmpty) {
                        setState(
                          () => error = words(
                            context,
                            '请填写修改意见',
                            'Enter revision notes',
                          ),
                        );
                        return;
                      }
                      submit({'action': 'revise', 'text': feedback.text});
                    },
              child: Text(words(context, '按照修改意见继续规划', 'Revise the plan')),
            ),
          ] else if (computer.isNotEmpty)
            Wrap(
              children: [
                if ((computer['persistModes'] as List? ?? []).contains(
                  'always',
                ))
                  button('始终允许', 'Always allow', {
                    'action': 'accept',
                    'persist': 'always',
                  }),
                button('拒绝', 'Decline', {'action': 'decline'}),
                if ((computer['persistModes'] as List? ?? []).contains(
                  'session',
                ))
                  button('允许此对话', 'Allow for this chat', {
                    'action': 'accept',
                    'persist': 'session',
                  })
                else
                  button('本次允许', 'Allow once', {'action': 'accept'}),
              ],
            )
          else if (isInput) ...[
            for (var i = 0; i < questions.length; i++)
              question(questions[i], i),
            FilledButton(
              onPressed: busy ? null : answers,
              child: Text(words(context, '提交回答', 'Submit answers')),
            ),
            if (!codex && scope.session.provider == Provider.claude)
              button('拒绝', 'Decline', {'decision': 'decline'}),
          ] else if (isMcp) ...[
            for (final entry in jsonObject(
              jsonObject(params['requestedSchema'])['properties'],
            ).entries)
              mcpField(entry.key, jsonObject(entry.value)),
            FilledButton(
              onPressed: busy ? null : acceptMcp,
              child: Text(words(context, '提交', 'Submit')),
            ),
            Wrap(
              children: [
                button('拒绝', 'Decline', {'action': 'decline'}),
                button('取消请求', 'Cancel request', {'action': 'cancel'}),
              ],
            ),
          ] else
            Wrap(
              children: [
                for (final decision
                    in params['availableDecisions'] as List? ??
                        (codex
                            ? [
                                'accept',
                                'decline',
                                if (method.contains('commandExecution') ||
                                    method.contains('fileChange'))
                                  'cancel',
                              ]
                            : ['accept', 'decline']))
                  button(
                    {
                          'accept': '允许本次',
                          'decline': '拒绝',
                          'cancel': '取消请求',
                          'acceptForSession': '允许此对话',
                        }[decision] ??
                        textValue(decision),
                    {
                          'accept': 'Allow once',
                          'decline': 'Decline',
                          'cancel': 'Cancel request',
                          'acceptForSession': 'Allow for this chat',
                        }[decision] ??
                        textValue(decision),
                    {'decision': decision},
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget question(Json q, int i) {
    final key = questionKey(q, i),
        controller = inputs.putIfAbsent(key, () => TextEditingController());
    final selected = selections.putIfAbsent(key, () => {});
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            textValue(q['question'] ?? q['header'] ?? key),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          for (final option in jsonRows(q['options']))
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(textValue(option['label'])),
              subtitle: Text(textValue(option['description'])),
              value: selected.contains(option['label']),
              onChanged: busy
                  ? null
                  : (v) => setState(() {
                      if (q['multiSelect'] != true) selected.clear();
                      if (v == true) {
                        selected.add(textValue(option['label']));
                      } else {
                        selected.remove(option['label']);
                      }
                    }),
            ),
          TextField(
            controller: controller,
            enabled: !busy,
            obscureText: q['isSecret'] == true,
            decoration: InputDecoration(
              labelText: words(
                context,
                '自行填写 / 补充回答',
                'Custom / additional answer',
              ),
            ),
          ),
          if (method == 'bridge/requestUserInputAsync')
            button('跳过此问题', 'Skip this question', {
              'action': 'skip',
              'questionId': q['id'],
            }),
        ],
      ),
    );
  }

  Widget mcpField(String key, Json field) {
    final title = textValue(field['title'] ?? key);
    if (field['type'] == 'boolean') {
      mcp.putIfAbsent(key, () => false);
      return SwitchListTile(
        title: Text(title),
        value: mcp[key] == true,
        onChanged: busy ? null : (v) => setState(() => mcp[key] = v),
      );
    }
    if (field['enum'] is List) {
      return ListTile(
        title: Text(title),
        subtitle: Text(textValue(mcp[key])),
        onTap: busy
            ? null
            : () async {
                final choices = field['enum'] as List,
                    names = field['enumNames'] as List? ?? [];
                final selected = await chooseValue<int>(context, title, {
                  for (var i = 0; i < choices.length; i++)
                    i: textValue(i < names.length ? names[i] : choices[i]),
                });
                if (selected != null && mounted) {
                  setState(() => mcp[key] = choices[selected]);
                }
              },
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextField(
        controller: inputs.putIfAbsent(key, () => TextEditingController()),
        enabled: !busy,
        keyboardType: ['number', 'integer'].contains(field['type'])
            ? const TextInputType.numberWithOptions(decimal: true, signed: true)
            : TextInputType.text,
        decoration: InputDecoration(
          labelText: title,
          helperText: field['description'] as String?,
        ),
      ),
    );
  }
}
