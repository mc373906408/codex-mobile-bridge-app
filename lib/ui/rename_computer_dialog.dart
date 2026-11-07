import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/bridge_repository.dart';
import '../l10n/strings.dart';
import '../viewmodels/bridge_view_model.dart';

Future<void> renameComputerDialog(
  BuildContext context, {
  required BridgeViewModel model,
  required Computer computer,
  required Strings strings,
}) {
  Widget builder(BuildContext context) =>
      _RenameComputerDialog(model: model, computer: computer, strings: strings);
  return Theme.of(context).platform == TargetPlatform.iOS
      ? showCupertinoDialog<void>(context: context, builder: builder)
      : showDialog<void>(context: context, builder: builder);
}

class _RenameComputerDialog extends StatefulWidget {
  const _RenameComputerDialog({
    required this.model,
    required this.computer,
    required this.strings,
  });
  final BridgeViewModel model;
  final Computer computer;
  final Strings strings;

  @override
  State<_RenameComputerDialog> createState() => _RenameComputerDialogState();
}

class _RenameComputerDialogState extends State<_RenameComputerDialog> {
  static const _maxNameLength = 64;
  late final _name =
      TextEditingController(text: widget.model.computerName(widget.computer))
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.model.computerName(widget.computer).length,
        );
  bool _saving = false;
  String? _error;

  bool get _canSave =>
      !_saving &&
      !widget.model.busy &&
      widget.model.foreground &&
      !widget.model.renamingComputer;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_canSave) return;
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Enter a device name');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.model.renameComputer(
        widget.computer,
        _name.text,
      );
      if (!mounted) return;
      if (saved) {
        Navigator.pop(context);
      } else {
        setState(() => _error = 'Could not save the name. Try again.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not save the name. Try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) => PopScope(
      canPop: !_saving,
      child: Theme.of(context).platform == TargetPlatform.iOS
          ? _cupertinoDialog()
          : _materialDialog(),
    ),
  );

  Widget _cupertinoDialog() {
    final s = widget.strings;
    return CupertinoAlertDialog(
      key: const Key('rename-computer-dialog'),
      title: Text(s.t('Rename computer')),
      content: Column(
        children: [
          Text(s.t('Only changes the name in this app.')),
          const SizedBox(height: 12),
          CupertinoTextField(
            key: const Key('computer-name'),
            controller: _name,
            autofocus: true,
            enabled: !_saving,
            maxLength: _maxNameLength,
            placeholder: s.t('Device name'),
            inputFormatters: [FilteringTextInputFormatter.singleLineFormatter],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
          ),
          if (_error != null) _errorLabel(),
        ],
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(s.t('Cancel')),
        ),
        CupertinoDialogAction(
          key: const Key('save-computer-name'),
          isDefaultAction: true,
          onPressed: _canSave ? _save : null,
          child: Text(s.t('Save')),
        ),
      ],
    );
  }

  Widget _errorLabel() => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(
      widget.strings.t(_error!),
      style: TextStyle(color: CupertinoColors.systemRed.resolveFrom(context)),
    ),
  );

  Widget _materialDialog() {
    final s = widget.strings;
    return AlertDialog(
      key: const Key('rename-computer-dialog'),
      scrollable: true,
      title: Text(s.t('Rename computer')),
      content: TextField(
        key: const Key('computer-name'),
        controller: _name,
        autofocus: true,
        enabled: !_saving,
        maxLength: _maxNameLength,
        inputFormatters: [FilteringTextInputFormatter.singleLineFormatter],
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        decoration: InputDecoration(
          labelText: s.t('Device name'),
          helperText: s.t('Only changes the name in this app.'),
          helperMaxLines: 3,
          errorText: _error == null ? null : s.t(_error!),
          errorMaxLines: 3,
          counterText: '',
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(s.t('Cancel')),
        ),
        FilledButton(
          key: const Key('save-computer-name'),
          onPressed: _canSave ? _save : null,
          child: Text(s.t('Save')),
        ),
      ],
    );
  }
}
