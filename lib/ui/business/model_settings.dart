import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import 'common.dart';

Future<void> scopedModelDialog(BuildContext context, SessionBusiness scope) =>
    showDialog<void>(
      context: context,
      builder: (_) => _ModelSettings(scope: scope),
    );

class _ModelSettings extends StatefulWidget {
  const _ModelSettings({required this.scope});
  final SessionBusiness scope;
  @override
  State<_ModelSettings> createState() => _ModelSettingsState();
}

class _ModelSettingsState extends State<_ModelSettings> {
  final customModel = TextEditingController(),
      customEffort = TextEditingController();
  Json catalog = {};
  String model = '', effort = '';
  bool loading = true, saving = false, fast = false, fastEdited = false;
  Object? error;
  int revision = 0;
  SessionBusiness get scope => widget.scope;
  List<Json> get models => jsonRows(catalog['models']);
  Json get selected => models.where((r) => r['id'] == model).firstOrNull ?? {};
  Json get caps => {
    ...jsonObject(catalog['capabilities']),
    ...scope.capabilities,
  };
  bool get manualModels =>
      scope.session.provider != Provider.codex && caps['manualModels'] == true;
  List<String> get efforts => (selected['efforts'] as List? ?? [])
      .map((v) => v is Map ? textValue(v['id']) : textValue(v))
      .where((v) => v.isNotEmpty)
      .toSet()
      .toList();
  bool get fastAvailable =>
      jsonObject(catalog['fastMode'])['allowed'] == true &&
      scope.state['provider'] ==
          (jsonObject(catalog['fastMode'])['provider'] ?? 'openai') &&
      selected['fastTier'] != null;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    revision++;
    customModel.dispose();
    customEffort.dispose();
    super.dispose();
  }

  void selectModel(String value, {String? initialEffort}) {
    model = value;
    final options = efforts;
    final preferred = initialEffort ?? textValue(selected['defaultEffort']);
    effort = options.contains(preferred)
        ? preferred
        : options.firstOrNull ?? '';
    if (preferred.isNotEmpty &&
        !options.contains(preferred) &&
        caps['manualEffort'] == true) {
      effort = '__custom__';
      customEffort.text = preferred;
    }
    final tier = scope.state.containsKey('serviceTier')
        ? scope.state['serviceTier']
        : catalog.containsKey('currentServiceTier')
        ? catalog['currentServiceTier']
        : jsonObject(catalog['fastMode'])['defaultServiceTier'] ??
              selected['defaultServiceTier'];
    fast =
        tier != null &&
        ['fast', 'priority', selected['fastTier']].contains(tier);
    fastEdited = false;
  }

  Future<void> load({bool refresh = false}) async {
    final request = ++revision;
    setState(() => loading = true);
    try {
      final result = await scope.read(SessionResource.catalog, {
        'kind': 'models',
        'refresh': refresh,
      });
      if (!mounted || revision != request) return;
      final expected = textValue(
        scope.metadata['modelCatalogIdentity'] ??
            scope.state['modelCatalogIdentity'],
      );
      if (expected.isNotEmpty &&
          jsonObject(result['cache'])['identity'] != expected) {
        throw StateError('Model account changed; reopen settings');
      }
      setState(() {
        catalog = result;
        final current = scope.snapshot.model.isNotEmpty
            ? scope.snapshot.model
            : textValue(result['currentModel']);
        final choice = models.any((r) => r['id'] == current)
            ? current
            : manualModels
            ? '__custom__'
            : models.firstOrNull?['id'] as String? ?? '';
        customModel.text = current;
        selectModel(
          choice,
          initialEffort: scope.snapshot.effort.isNotEmpty
              ? scope.snapshot.effort
              : textValue(result['currentEffort']),
        );
        error = null;
      });
    } catch (e) {
      if (mounted && revision == request) setState(() => error = e);
    } finally {
      if (mounted && revision == request) setState(() => loading = false);
    }
  }

  Future<void> save() async {
    final chosen = model == '__custom__' ? customModel.text.trim() : model;
    final reasoning = effort == '__custom__'
        ? customEffort.text.trim()
        : effort;
    if (chosen.isEmpty || (effort == '__custom__' && reasoning.isEmpty)) return;
    setState(() => saving = true);
    try {
      final identity = jsonObject(catalog['cache'])['identity'];
      await scope.write(SessionCommand.settings, {
        'model': chosen,
        if (reasoning.isNotEmpty) 'effort': reasoning,
        if (scope.session.provider != Provider.codex &&
            identity is String &&
            identity.isNotEmpty)
          'modelCatalogIdentity': identity,
        if (model == '__custom__') 'manualModel': true,
        if (effort == '__custom__') 'manualEffort': true,
        if (fastAvailable && fastEdited) 'fastMode': fast,
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(words(context, '模型与思考强度', 'Model & reasoning')),
    content: SizedBox(
      width: 450,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading) const LinearProgressIndicator(),
            if (error != null) SelectableText(businessError(context, error)),
            if (catalog['notice'] != null) Text(textValue(catalog['notice'])),
            if (models.isNotEmpty || manualModels)
              DropdownButtonFormField<String>(
                key: ValueKey(('model', model, revision)),
                initialValue: model.isEmpty ? null : model,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: words(context, '模型', 'Model'),
                ),
                items: [
                  for (final row in models)
                    DropdownMenuItem(
                      value: textValue(row['id']),
                      child: Text(
                        textValue(
                          row['name'] ?? row['displayName'] ?? row['id'],
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (manualModels)
                    DropdownMenuItem(
                      value: '__custom__',
                      child: Text(words(context, '手动输入', 'Manual')),
                    ),
                ],
                onChanged: loading || saving
                    ? null
                    : (v) => setState(() => selectModel(v!)),
              ),
            if (model == '__custom__')
              TextField(
                controller: customModel,
                enabled: !saving,
                maxLength: 300,
                decoration: InputDecoration(
                  labelText: words(context, '模型名称', 'Model name'),
                ),
              ),
            if (caps['effort'] != false &&
                (efforts.isNotEmpty || caps['manualEffort'] == true))
              DropdownButtonFormField<String>(
                key: ValueKey(('effort', model, effort)),
                initialValue: effort.isEmpty ? null : effort,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: words(context, '思考强度', 'Reasoning effort'),
                ),
                items: [
                  for (final v in efforts)
                    DropdownMenuItem(value: v, child: Text(v)),
                  if (caps['manualEffort'] == true)
                    DropdownMenuItem(
                      value: '__custom__',
                      child: Text(words(context, '手动输入', 'Manual')),
                    ),
                ],
                onChanged: loading || saving
                    ? null
                    : (v) => setState(() => effort = v!),
              ),
            if (effort == '__custom__')
              TextField(
                controller: customEffort,
                enabled: !saving,
                maxLength: 64,
                decoration: InputDecoration(
                  labelText: words(context, '思考强度', 'Reasoning effort'),
                ),
              ),
            if (fastAvailable)
              SwitchListTile(
                title: const Text('Fast'),
                value: fast,
                onChanged: saving
                    ? null
                    : (v) => setState(() {
                        fast = v;
                        fastEdited = true;
                      }),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: loading || saving ? null : () => load(refresh: true),
        child: Text(words(context, '刷新目录', 'Refresh catalog')),
      ),
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: Text(words(context, '取消', 'Cancel')),
      ),
      FilledButton(
        onPressed: loading || saving || model.isEmpty || error != null
            ? null
            : save,
        child: Text(words(context, '应用', 'Apply')),
      ),
    ],
  );
}
