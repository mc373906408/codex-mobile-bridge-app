import 'dart:io';

import 'package:flutter/material.dart';

import '../data/bridge_repository.dart';
import '../l10n/strings.dart';
import '../viewmodels/cloud_view_model.dart';
import 'cloud_dialog.dart';
import 'pairing_scan_page.dart';
import 'cloud_status_widgets.dart';
import 'business/creation_page.dart';
import 'business/common.dart';
import 'business/model_settings.dart';

Future<bool?> cloudComputerDialog(
  BuildContext context,
  BridgeViewModel model,
  Strings s, {
  required CloudViewModel cloud,
  required Computer computer,
}) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => CloudConnectionDialog(
    model: model,
    cloud: cloud,
    strings: s,
    computer: computer,
  ),
);

Future<void> removeComputerDialog(
  BuildContext context,
  BridgeViewModel model,
  Computer computer,
  Strings s,
) async {
  if (model.busy ||
      !model.foreground ||
      computer.connectionType == ConnectionType.relay) {
    return;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('remove-connection-dialog'),
      scrollable: true,
      title: Text(s.t('Remove connection')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            model.computerName(computer),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(cloudServerLabel(computer.relay?.origin ?? computer.baseUrl, s)),
          const SizedBox(height: 20),
          Text(
            s.t(
              'Remove the saved connection, credentials, drafts and pending records from this phone?',
            ),
          ),
          const SizedBox(height: 12),
          Text(
            s.t(
              'The gateway and conversations on your computer are not deleted.',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context, false),
          child: Text(s.t('Cancel')),
        ),
        FilledButton(
          key: const Key('confirm-remove-connection'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: Text(s.t('Remove')),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await model.removeComputer(computer);
  } catch (error) {
    model.reportError(error);
  }
}

Future<void> addComputerDialog(
  BuildContext context,
  BridgeViewModel model,
  Strings s, {
  VoidCallback? onCloud,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      _AddComputerDialog(model: model, strings: s, onCloud: onCloud),
);

class _AddComputerDialog extends StatefulWidget {
  const _AddComputerDialog({
    required this.model,
    required this.strings,
    this.onCloud,
  });
  final BridgeViewModel model;
  final Strings strings;
  final VoidCallback? onCloud;
  @override
  State<_AddComputerDialog> createState() => _AddComputerDialogState();
}

class _AddComputerDialogState extends State<_AddComputerDialog> {
  final _name = TextEditingController(), _address = TextEditingController();
  bool _saving = false;
  Object? _error;
  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.model.addComputer(_name.text, _address.text);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.strings;
    return AlertDialog(
      title: Text(s.t('Add computer')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.t(
                  'Paste the address or pairing link shown on your computer.',
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _name,
                decoration: InputDecoration(
                  labelText: s.t('Name'),
                  prefixIcon: const Icon(Icons.computer_rounded),
                ),
                maxLength: 80,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _address,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: s.t('Gateway address'),
                  hintText: 'https://gateway.example',
                ),
                onSubmitted: (_) {
                  if (!_saving) _save();
                },
              ),
              const SizedBox(height: 12),
              Text(
                s.t(
                  'HTTP and HTTPS addresses are supported. HTTP does not encrypt credentials or gateway traffic.',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (widget.onCloud case final onCloud?)
                OutlinedButton.icon(
                  onPressed: _saving
                      ? null
                      : () {
                          Navigator.pop(context);
                          onCloud();
                        },
                  icon: const Icon(Icons.cloud_outlined),
                  label: Text(s.t('Cloud relay')),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _saving || !(Platform.isAndroid || Platform.isIOS)
                    ? null
                    : () async {
                        final value = await Navigator.push<String>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ScanPage(strings: s),
                          ),
                        );
                        if (mounted && value != null) _address.text = value;
                      },
                icon: const Icon(Icons.qr_code_scanner),
                label: Text(
                  s.t(
                    Platform.isAndroid || Platform.isIOS
                        ? 'Scan QR'
                        : 'Scan on your phone',
                  ),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    s.error(_error!),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(s.t('Cancel')),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(s.t('Save and connect')),
        ),
      ],
    );
  }
}

Future<void> modelDialog(
  BuildContext context,
  BridgeViewModel model,
  Strings s,
) async {
  final snapshot = model.snapshot;
  if (snapshot == null) return;
  final scope = SessionBusiness(model, snapshot);
  try {
    await scopedModelDialog(context, scope);
  } catch (error) {
    model.reportError(error);
  } finally {
    scope.dispose();
  }
}

Future<List<QuestionAnswer>?> answerDialog(
  BuildContext context,
  ApprovalRequest request,
  Strings s,
) => showDialog<List<QuestionAnswer>>(
  context: context,
  builder: (_) => _AnswerDialog(request: request, strings: s),
);

class _AnswerDialog extends StatefulWidget {
  const _AnswerDialog({required this.request, required this.strings});
  final ApprovalRequest request;
  final Strings strings;
  @override
  State<_AnswerDialog> createState() => _AnswerDialogState();
}

class _AnswerDialogState extends State<_AnswerDialog> {
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, Set<String>> _selected = {};
  @override
  void initState() {
    super.initState();
    for (final q in widget.request.questions) {
      _controllers[q.id] = TextEditingController();
      _selected[q.id] = {};
    }
  }

  @override
  void dispose() {
    for (final value in _controllers.values) {
      value.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.strings.t('Answer')),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final question in widget.request.questions) ...[
              Text(
                question.question,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              for (final option in question.options)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: _selected[question.id]!.contains(option.label),
                  title: Text(option.label),
                  subtitle: option.description.isEmpty
                      ? null
                      : Text(option.description),
                  onChanged: (value) => setState(() {
                    if (!question.multiple) _selected[question.id]!.clear();
                    if (value == true) {
                      _selected[question.id]!.add(option.label);
                    } else {
                      _selected[question.id]!.remove(option.label);
                    }
                  }),
                ),
              TextField(
                controller: _controllers[question.id],
                obscureText: question.secret,
                maxLength: 20000,
                decoration: InputDecoration(
                  labelText: widget.strings.t('Answer'),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(widget.strings.t('Cancel')),
      ),
      FilledButton(
        onPressed: () {
          final answers = [
            for (final question in widget.request.questions)
              QuestionAnswer(
                questionId: question.id,
                values: [
                  ..._selected[question.id]!,
                  if (_controllers[question.id]!.text.trim().isNotEmpty)
                    _controllers[question.id]!.text.trim(),
                ],
              ),
          ];
          if (answers.any((answer) => answer.values.isEmpty)) return;
          Navigator.pop(context, answers);
        },
        child: Text(widget.strings.t('Submit answers')),
      ),
    ],
  );
}

Future<void> newChatDialog(
  BuildContext context,
  BridgeViewModel model,
  Strings s,
) => openCreationDialog(context, model);

Future<void> pendingCreationsDialog(
  BuildContext context,
  BridgeViewModel model,
  Strings s,
) async {
  final computer = model.computer;
  if (computer == null) return;
  final rows = [...model.pendingCreations];
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(s.t('Pending verification')),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                s.t(
                  'Only confirm after checking the original conversation. This does not resend anything or claim that the operation succeeded.',
                ),
              ),
              for (final row in rows)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${row.provider.name} / ${row.environment}'),
                  subtitle: SelectableText(
                    '${row.projectKey}\n${row.operation.id}',
                    style: const TextStyle(
                      fontFamily: 'PlexMono',
                      fontSize: 11,
                    ),
                  ),
                  trailing: IconButton(
                    tooltip: s.t('I checked on the computer'),
                    icon: const Icon(Icons.check_circle_outline),
                    onPressed: () async {
                      Navigator.pop(context);
                      try {
                        await model.reviewCreation(computer, row);
                      } catch (error) {
                        model.reportError(error);
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.t('Cancel')),
        ),
      ],
    ),
  );
}
