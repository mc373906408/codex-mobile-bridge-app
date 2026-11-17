import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import '../design/bridge_theme.dart';
import 'common.dart';

Future<void> skillPickerDialog(BuildContext context, SessionBusiness scope) =>
    showDialog<void>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (_) => SkillPickerDialog(scope: scope),
    );

class SkillPickerDialog extends StatefulWidget {
  const SkillPickerDialog({super.key, required this.scope});
  final SessionBusiness scope;
  @override
  State<SkillPickerDialog> createState() => _SkillPickerState();
}

class _SkillPickerState extends State<SkillPickerDialog> {
  final searchController = TextEditingController();
  final searchFocus = FocusNode();
  List<Json> rows = [];
  String query = '';
  int total = 0, loaded = 0, revision = 0;
  bool loading = true;
  Timer? searchTimer;
  Object? error;
  SessionBusiness get scope => widget.scope;
  bool get current =>
      scope.current &&
      scope.model.selected == scope.session &&
      scope.model.snapshot?.accountIdentity == scope.snapshot.accountIdentity;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    revision++;
    searchTimer?.cancel();
    searchController.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  void search(String value) {
    searchTimer?.cancel();
    revision++;
    setState(() {
      query = value;
      rows = [];
      loaded = total = 0;
      error = null;
      loading = true;
    });
    searchTimer = Timer(const Duration(milliseconds: 200), load);
  }

  Future<void> load({bool more = false, bool refresh = false}) async {
    searchTimer?.cancel();
    if (!current) return;
    final request = ++revision, offset = more ? loaded : 0;
    final searchQuery = query;
    setState(() => loading = true);
    try {
      final data = await scope.read(SessionResource.catalog, {
        'kind': 'skills',
        'q': searchQuery,
        'offset': offset,
        'limit': 200,
        'refresh': refresh,
      });
      if (!mounted || request != revision || !current) return;
      final offered = jsonRows(data['skills']);
      final visible = offered.where(
        (row) =>
            scope.session.provider == Provider.codex ||
            searchQuery.isEmpty ||
            '${row['name']} ${row['displayName']} ${row['description']}'
                .toLowerCase()
                .contains(searchQuery.toLowerCase()),
      );
      setState(() {
        rows = [if (more) ...rows, ...visible];
        loaded = offset + offered.length;
        total = offered.isEmpty
            ? loaded
            : (data['total'] as num?)?.toInt() ?? loaded;
        error = null;
      });
    } catch (e) {
      if (mounted && request == revision) setState(() => error = e);
    } finally {
      if (mounted && request == revision) setState(() => loading = false);
    }
  }

  void select(String id, bool checked) {
    final model = scope.model;
    if (!current || !model.draftEditable || model.busy) return;
    final selected = (model.draftOptions['skills'] as List? ?? [])
        .whereType<String>()
        .toSet();
    if (checked && selected.length >= 8 && !selected.contains(id)) return;
    checked ? selected.add(id) : selected.remove(id);
    model.setDraftOption('skills', selected.toList());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: scope.model,
    builder: (context, _) {
      final theme = Theme.of(context), colors = theme.colorScheme;
      final selected = (scope.model.draftOptions['skills'] as List? ?? [])
          .whereType<String>()
          .toSet();
      final enabled = current && scope.model.draftEditable && !scope.model.busy;
      return Dialog(
        key: const Key('skill-picker-dialog'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        constraints: const BoxConstraints(maxWidth: 480),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxHeight < 480 ||
                MediaQuery.textScalerOf(context).scale(14) > 21;
            final help = Text(
              words(
                context,
                '选择后随下一条消息一起发送，最多 8 个。',
                'Selected Skills are sent with your next message. Choose up to 8.',
              ),
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: colors.onSurfaceVariant,
              ),
            );
            final searchField = TextField(
              key: const Key('skill-search'),
              controller: searchController,
              focusNode: searchFocus,
              enabled: current,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: words(
                  context,
                  '搜索已安装 Skill',
                  'Search installed Skills',
                ),
              ),
              onChanged: search,
              onSubmitted: (_) => load(),
            );
            final entries = <Widget>[
              if (loading)
                const Padding(
                  padding: EdgeInsets.only(bottom: 10),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              if (!current || error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    current
                        ? businessError(context, error)
                        : words(
                            context,
                            '聊天已切换，请重新打开 Skill 选择。',
                            'Chat changed. Reopen the Skill picker.',
                          ),
                    style: TextStyle(fontSize: 12, color: colors.error),
                  ),
                ),
              if (rows.isEmpty && !loading && error == null && current)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                    words(context, '没有匹配的 Skill', 'No matching Skills'),
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: colors.surfaceContainer,
                    borderRadius: BorderRadius.circular(10),
                    clipBehavior: Clip.antiAlias,
                    child: CheckboxListTile(
                      key: ValueKey('skill-${row['id']}'),
                      controlAffinity: ListTileControlAffinity.leading,
                      titleAlignment: ListTileTitleAlignment.top,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      title: Text(
                        textValue(
                          row['displayName'] ?? row['name'] ?? row['id'],
                        ),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text(
                          textValue(row['description']),
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                      value: selected.contains(row['id']),
                      onChanged:
                          !enabled ||
                              textValue(row['id']).isEmpty ||
                              row['selectable'] == false ||
                              (!selected.contains(row['id']) &&
                                  selected.length >= 8)
                          ? null
                          : (value) =>
                                select(textValue(row['id']), value == true),
                    ),
                  ),
                ),
              if (loaded < total)
                TextButton(
                  onPressed: loading || !current
                      ? null
                      : () => load(more: true),
                  child: Text(words(context, '加载更多', 'Load more')),
                ),
            ];
            final introduction = <Widget>[
              help,
              const SizedBox(height: 14),
              searchField,
              const SizedBox(height: 16),
            ];
            return SizedBox(
              width: double.infinity,
              height: constraints.maxHeight.clamp(0, 680),
              child: BridgeGlass(
                style: BridgeGlassStyle.regular,
                radius: 20,
                padding: EdgeInsets.all(compact ? 12 : 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            words(context, '选择 Skill', 'Choose Skills'),
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontSize: 21,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          key: const Key('close-skills'),
                          tooltip: words(
                            context,
                            '关闭 Skill 选择',
                            'Close Skill picker',
                          ),
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: compact
                          ? ListView(
                              key: const Key('skill-list'),
                              padding: EdgeInsets.zero,
                              children: [...introduction, ...entries],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                ...introduction,
                                Expanded(
                                  child: ListView(
                                    key: const Key('skill-list'),
                                    padding: EdgeInsets.zero,
                                    children: entries,
                                  ),
                                ),
                              ],
                            ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Flexible(
                          child: TextButton(
                            key: const Key('refresh-skills'),
                            onPressed: loading || !current
                                ? null
                                : () => load(refresh: true),
                            child: Text(
                              words(context, '刷新列表', 'Refresh list'),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: FilledButton(
                            key: const Key('done-skills'),
                            onPressed: () => Navigator.pop(context),
                            child: Text(words(context, '完成', 'Done')),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    },
  );
}
