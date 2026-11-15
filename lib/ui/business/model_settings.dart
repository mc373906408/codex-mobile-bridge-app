import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import 'common.dart';
import '../design/bridge_theme.dart';
import '../design/selection_controls.dart';

Future<void> scopedModelDialog(BuildContext context, SessionBusiness scope) =>
    showDialog<void>(
      context: context,
      barrierColor: Colors.transparent,
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
  bool selectionEdited = false;
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
    final cached = scope.model.cachedModelCatalog(scope.snapshot);
    if (cached != null) useCatalog(cached);
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
      final result = await scope.model.loadModelCatalog(
        scope.snapshot,
        refresh: refresh,
      );
      if (!mounted || revision != request) return;
      setState(() {
        useCatalog(result, preserve: refresh || selectionEdited);
        error = null;
      });
    } catch (e) {
      if (mounted && revision == request) setState(() => error = e);
    } finally {
      if (mounted && revision == request) setState(() => loading = false);
    }
  }

  void useCatalog(Json result, {bool preserve = false}) {
    final previous = model, previousEffort = effort;
    catalog = result;
    final current = preserve && previous.isNotEmpty
        ? previous
        : scope.snapshot.model.isNotEmpty
        ? scope.snapshot.model
        : textValue(result['currentModel']);
    final choice = models.any((row) => row['id'] == current)
        ? current
        : manualModels
        ? '__custom__'
        : '';
    customModel.text = current;
    selectModel(
      choice,
      initialEffort: preserve
          ? previousEffort
          : scope.snapshot.effort.isNotEmpty
          ? scope.snapshot.effort
          : textValue(result['currentEffort']),
    );
    loading = false;
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final short = MediaQuery.sizeOf(context).height < 500;
    final updated = jsonObject(catalog['cache'])['updatedAt'];
    final date = updated is num && updated > 0
        ? DateTime.fromMillisecondsSinceEpoch((updated * 1000).round())
              .toLocal()
        : null;
    String digits(int value) => value.toString().padLeft(2, '0');
    final available = !saving && scope.current;
    Widget label(String zh, String en) => Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Text(
        words(context, zh, en),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
    return Dialog(
      key: const Key('model-settings-dialog'),
      insetPadding: EdgeInsets.symmetric(
        horizontal: 16,
        vertical: short ? 12 : 24,
      ),
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: BridgeGlass(
          style: BridgeGlassStyle.regular,
          radius: 20,
          padding: EdgeInsets.all(short ? 12 : 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      words(context, '模型设置', 'Model settings'),
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (MediaQuery.sizeOf(context).width > 350 && !short)
                    OutlinedButton.icon(
                      key: const Key('refresh-models'),
                      onPressed: loading || !available
                          ? null
                          : () => load(refresh: true),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(44, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        shape: const StadiumBorder(),
                      ),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: Text(words(context, '刷新', 'Refresh')),
                    )
                  else
                    IconButton(
                      key: const Key('refresh-models'),
                      onPressed: loading || !available
                          ? null
                          : () => load(refresh: true),
                      tooltip: words(context, '刷新', 'Refresh'),
                      icon: const Icon(Icons.refresh),
                    ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: saving ? null : () => Navigator.pop(context),
                    tooltip: words(context, '关闭模型设置', 'Close model settings'),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (loading) ...[
                        const LinearProgressIndicator(minHeight: 2),
                        const SizedBox(height: 12),
                      ],
                      if (date != null) ...[
                        Text(
                          '${words(context, '更新于：', 'Updated: ')}${date.year}/${digits(date.month)}/${digits(date.day)} '
                          '${digits(date.hour)}:${digits(date.minute)}:${digits(date.second)}',
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 18),
                      ],
                      if (error != null) ...[
                        Text(
                          businessError(context, error),
                          style: TextStyle(fontSize: 13, color: colors.error),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (catalog['notice'] != null) ...[
                        Text(textValue(catalog['notice'])),
                        const SizedBox(height: 12),
                      ],
                      label('模型', 'Model'),
                      if (models.isNotEmpty || manualModels)
                        BridgeOptionList(
                          options: {
                            for (final row in models)
                              textValue(row['id']): textValue(
                                row['name'] ?? row['displayName'] ?? row['id'],
                              ),
                            if (manualModels)
                              '__custom__': words(
                                context,
                                '自定义模型…',
                                'Custom model…',
                              ),
                          },
                          value: model,
                          height: MediaQuery.sizeOf(context).height < 700
                              ? 173
                              : 218,
                          onChanged: available
                              ? (value) => setState(() {
                                  selectionEdited = true;
                                  selectModel(value, initialEffort: effort);
                                })
                              : null,
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            words(
                              context,
                              loading ? '读取模型列表…' : '模型目录读取失败，请刷新后重试',
                              loading ? 'Loading models…' : 'Unable to load models. Refresh to try again.',
                            ),
                          ),
                        ),
                      if (model == '__custom__') ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: customModel,
                          enabled: available,
                          maxLength: 300,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            labelText: words(context, '模型名称', 'Model name'),
                          ),
                        ),
                      ],
                      if (caps['effort'] != false &&
                          (efforts.isNotEmpty ||
                              caps['manualEffort'] == true)) ...[
                        const SizedBox(height: 18),
                        label('思考强度', 'Reasoning effort'),
                        BridgeChoiceGrid(
                          options: {
                            for (final value in efforts)
                              value: reasoningLabel(context, value),
                            if (caps['manualEffort'] == true)
                              '__custom__': words(context, '自定义', 'Custom'),
                          },
                          value: effort,
                          onChanged: available
                              ? (value) => setState(() {
                                  selectionEdited = true;
                                  effort = value;
                                })
                              : null,
                        ),
                      ],
                      if (effort == '__custom__') ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: customEffort,
                          enabled: available,
                          maxLength: 64,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            labelText: words(
                              context,
                              '思考强度',
                              'Reasoning effort',
                            ),
                          ),
                        ),
                      ],
                      if (fastAvailable) ...[
                        const SizedBox(height: 16),
                        const Divider(),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Fast'),
                          value: fast,
                          onChanged: available
                              ? (value) => setState(() {
                                  fast = value;
                                  fastEdited = true;
                                })
                              : null,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('apply-model'),
                onPressed:
                    !available ||
                        model.isEmpty ||
                        catalog.isEmpty ||
                        error != null ||
                        (loading && models.isEmpty) ||
                        model == '__custom__' &&
                            customModel.text.trim().isEmpty ||
                        effort == '__custom__' &&
                            customEffort.text.trim().isEmpty
                    ? null
                    : save,
                child: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        (MediaQuery.sizeOf(context).height -
                                    MediaQuery.viewInsetsOf(context).bottom <
                                360
                            ? words(context, '应用', 'Apply')
                            : words(context, '应用到此聊天', 'Apply to this chat')),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
