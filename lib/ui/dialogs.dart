import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../data/bridge_repository.dart';
import '../data/cloud_accounts.dart';
import '../l10n/strings.dart';
import '../viewmodels/bridge_view_model.dart';
import 'cloud_dialog.dart';

Future<bool?> cloudComputerDialog(
  BuildContext context,
  BridgeViewModel model,
  Strings s, {
  Computer? reconnect,
  String? invitation,
}) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => CloudConnectionDialog(
    model: model,
    strings: s,
    reconnect: reconnect,
    invitation: invitation,
    scan: (context) => Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => ScanPage(strings: s)),
    ),
  ),
);

Future<void> removeComputerDialog(
  BuildContext context,
  BridgeViewModel model,
  Computer computer,
  Strings s,
) async {
  if (model.busy || !model.foreground) return;
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
          Text(computer.name, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(computer.baseUrl),
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
  Strings s,
) => showDialog<void>(
  context: context,
  builder: (_) => _AddComputerDialog(model: model, strings: s),
);

class _AddComputerDialog extends StatefulWidget {
  const _AddComputerDialog({required this.model, required this.strings});
  final BridgeViewModel model;
  final Strings strings;
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
    if (_address.text.startsWith('bridge-relay:') &&
        widget.model.repository is CloudRepository) {
      await _cloud(invitation: _address.text);
      return;
    }
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

  Future<void> _cloud({String? invitation}) async {
    final connected = await cloudComputerDialog(
      context,
      widget.model,
      widget.strings,
      invitation: invitation,
    );
    if (mounted && connected == true) Navigator.pop(context);
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
                  'Public addresses require HTTPS. HTTP is allowed only for local networks.',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (widget.model.repository is CloudRepository)
                OutlinedButton.icon(
                  onPressed: _saving ? null : _cloud,
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

class ScanPage extends StatefulWidget {
  const ScanPage({super.key, required this.strings});
  final Strings strings;
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  bool _handled = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.strings.t('Scan QR'))),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            widget.strings.t('Point at the pairing QR code in your gateway.'),
          ),
        ),
        Expanded(
          child: MobileScanner(
            onDetect: (capture) {
              final value = capture.barcodes
                  .where((barcode) => barcode.rawValue != null)
                  .firstOrNull
                  ?.rawValue;
              if (_handled || value == null) return;
              _handled = true;
              Navigator.pop(context, value);
            },
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  widget.strings.t(
                    'Camera unavailable. Paste a pairing link instead.',
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

Future<void> modelDialog(
  BuildContext context,
  BridgeViewModel model,
  Strings s,
) async {
  final snapshot = model.snapshot;
  if (snapshot == null) return;
  try {
    final models = await model.repository.models(snapshot.session);
    if (!context.mounted || model.selected != snapshot.session) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _ModelDialog(
        model: model,
        snapshot: snapshot,
        options: models,
        strings: s,
      ),
    );
  } catch (error) {
    model.reportError(error);
  }
}

class _ModelDialog extends StatefulWidget {
  const _ModelDialog({
    required this.model,
    required this.snapshot,
    required this.options,
    required this.strings,
  });
  final BridgeViewModel model;
  final SessionSnapshot snapshot;
  final List<ModelOption> options;
  final Strings strings;
  @override
  State<_ModelDialog> createState() => _ModelDialogState();
}

class _ModelDialogState extends State<_ModelDialog> {
  ModelOption? _model;
  String _effort = '';
  @override
  void initState() {
    super.initState();
    _model =
        widget.options
            .where((option) => option.id == widget.snapshot.model)
            .firstOrNull ??
        widget.options.firstOrNull;
    _effort = _model?.efforts.contains(widget.snapshot.effort) == true
        ? widget.snapshot.effort
        : _model?.defaultEffort ?? '';
    if (_model?.efforts.isNotEmpty == true &&
        !_model!.efforts.contains(_effort)) {
      _effort = _model!.efforts.first;
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.strings.t('Model')),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<ModelOption>(
            initialValue: _model,
            isExpanded: true,
            items: [
              for (final option in widget.options)
                DropdownMenuItem(
                  value: option,
                  child: Text(option.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (value) => setState(() {
              _model = value;
              _effort = value?.efforts.firstOrNull ?? '';
            }),
            decoration: InputDecoration(labelText: widget.strings.t('Model')),
          ),
          const SizedBox(height: 16),
          if (_model?.efforts.isNotEmpty == true)
            DropdownButtonFormField<String>(
              key: ValueKey(_model!.id),
              initialValue: _effort,
              items: [
                for (final value in _model!.efforts)
                  DropdownMenuItem(value: value, child: Text(value)),
              ],
              onChanged: (value) => setState(() => _effort = value ?? ''),
              decoration: InputDecoration(
                labelText: widget.strings.t('Reasoning effort'),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(widget.strings.t('Cancel')),
      ),
      FilledButton(
        onPressed: _model == null
            ? null
            : () {
                Navigator.pop(context);
                widget.model.perform((current, id) {
                  if (current.session != widget.snapshot.session ||
                      current.controlToken != widget.snapshot.controlToken) {
                    throw StateError('Session changed; reopen model settings');
                  }
                  return widget.model.repository.settings(
                    widget.snapshot,
                    id,
                    _model!.id,
                    _effort,
                  );
                });
              },
        child: Text(widget.strings.t('Apply')),
      ),
    ],
  );
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
) async {
  final computer = model.computer;
  final provider = model.provider;
  final generation = model.connectionGeneration;
  if (computer == null) return;
  try {
    final projects = await model.repository.projects(
      computer,
      provider,
      model.selected?.environment ?? 'desktop',
    );
    if (!context.mounted ||
        model.connectionGeneration != generation ||
        model.provider != provider ||
        !model.foreground) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _NewChatDialog(
        model: model,
        projects: projects,
        strings: s,
        connection: generation,
      ),
    );
  } catch (error) {
    model.reportError(error);
  }
}

class _NewChatDialog extends StatefulWidget {
  const _NewChatDialog({
    required this.model,
    required this.projects,
    required this.strings,
    required this.connection,
  });
  final BridgeViewModel model;
  final List<ProjectOption> projects;
  final Strings strings;
  final int connection;
  @override
  State<_NewChatDialog> createState() => _NewChatDialogState();
}

class _NewChatDialogState extends State<_NewChatDialog> {
  final _title = TextEditingController(), _text = TextEditingController();
  ProjectOption? _project;
  @override
  void initState() {
    super.initState();
    _project = widget.projects.firstOrNull;
  }

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.strings.t('New chat')),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.projects.isEmpty)
              Text(widget.strings.t('Register a project in the gateway first.'))
            else
              DropdownButtonFormField<ProjectOption>(
                initialValue: _project,
                isExpanded: true,
                items: [
                  for (final value in widget.projects)
                    DropdownMenuItem(
                      value: value,
                      child: Text(
                        '${value.name} · ${value.environment}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => _project = value),
                decoration: InputDecoration(
                  labelText: widget.strings.t('Project'),
                ),
              ),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              maxLength: 120,
              decoration: InputDecoration(labelText: widget.strings.t('Title')),
            ),
            if (_project?.provider != Provider.codex)
              TextField(
                controller: _text,
                minLines: 2,
                maxLines: 5,
                maxLength: 100000,
                decoration: InputDecoration(
                  labelText: widget.strings.t('Opening message'),
                ),
              ),
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
        onPressed: _project == null
            ? null
            : () {
                if (_title.text.trim().isEmpty ||
                    _project!.requiresMessage && _text.text.trim().isEmpty) {
                  return;
                }
                Navigator.pop(context);
                widget.model.createChat(
                  _project!,
                  _title.text.trim(),
                  _text.text,
                  expectedConnection: widget.connection,
                );
              },
        child: Text(widget.strings.t('Create')),
      ),
    ],
  );
}

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
