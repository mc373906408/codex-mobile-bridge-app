import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/bridge_repository.dart';
import '../l10n/strings.dart';
import '../viewmodels/bridge_view_model.dart';

Future<void> renameComputerDialog(
  BuildContext context,
  BridgeViewModel model,
  Computer computer,
  Strings strings,
) => showDialog<void>(
  context: context,
  builder: (_) =>
      _RenameComputerDialog(model: model, computer: computer, strings: strings),
);

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
  late final _name = TextEditingController(
    text: widget.model.computerName(widget.computer),
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
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
    builder: (context, _) {
      final s = widget.strings;
      return PopScope(
        canPop: !_saving,
        child: AlertDialog(
          key: const Key('rename-computer-dialog'),
          scrollable: true,
          title: Text(s.t('Rename computer')),
          content: TextField(
            key: const Key('computer-name'),
            controller: _name,
            autofocus: true,
            enabled: !_saving,
            maxLength: 64,
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
              onPressed:
                  _saving ||
                      widget.model.busy ||
                      !widget.model.foreground ||
                      widget.model.renamingComputer
                  ? null
                  : _save,
              child: Text(s.t('Save')),
            ),
          ],
        ),
      );
    },
  );
}
