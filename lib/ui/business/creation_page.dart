import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import 'common.dart';

Future<void> openCreationDialog(
  BuildContext context,
  BridgeViewModel model,
) async {
  if (model.computer == null || !model.authenticated) return;
  final scope = GatewayBusiness(model);
  try {
    await showDialog<void>(
      context: context,
      builder: (_) => CreationDialog(scope: scope),
    );
  } finally {
    scope.dispose();
  }
}

class CreationDialog extends StatefulWidget {
  const CreationDialog({super.key, required this.scope});
  final GatewayBusiness scope;
  @override
  State<CreationDialog> createState() => _CreationState();
}

class _CreationState extends State<CreationDialog> {
  final title = TextEditingController(),
      message = TextEditingController(),
      manualModel = TextEditingController(),
      manualEffort = TextEditingController();
  Json? projects, catalog;
  String projectKey = '', environment = '', modelId = '', effort = '';
  Object? error;
  bool loading = true, saving = false;
  int revision = 0;
  GatewayBusiness get scope => widget.scope;
  bool get codex => scope.provider == Provider.codex;
  Json get project =>
      jsonRows(projects?['projects'])
          .where((r) => r['key'] == projectKey)
          .firstOrNull ??
      {};
  Json get env =>
      jsonRows(projects?['environments'])
          .where((r) => r['key'] == environment)
          .firstOrNull ??
      {};
  Json get selectedModel =>
      jsonRows(catalog?['models'])
          .where((r) => r['id'] == modelId)
          .firstOrNull ??
      {};
  Json get caps => jsonObject(catalog?['capabilities']);
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    for (final c in [title, message, manualModel, manualEffort]) {
      c.dispose();
    }
    revision++;
    super.dispose();
  }

  Future<void> load() async {
    try {
      final data = await scope.read(GatewayResource.projects);
      if (!mounted) return;
      setState(() {
        projects = data;
        environment =
            jsonRows(data['environments']).firstOrNull?['key']?.toString() ??
            '';
        projectKey =
            jsonRows(data['projects']).firstOrNull?['key']?.toString() ?? '';
        if (project.isNotEmpty) environment = textValue(project['environment']);
        loading = false;
      });
      await loadModels();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e;
          loading = false;
        });
      }
    }
  }

  Future<void> loadModels({bool refresh = false}) async {
    final rev = ++revision;
    if (projects?['createModels'] != true || projectKey.isEmpty) {
      setState(() => catalog = null);
      return;
    }
    setState(() {
      loading = true;
      catalog = null;
      modelId = '';
      effort = '';
      error = null;
    });
    try {
      final data = await scope.read(GatewayResource.creationModels, {
        if (codex) ...{
          'project': projectKey,
          'kind': textValue(project['type'] ?? env['type'] ?? 'desktop'),
        } else ...{
          'projectKey': projectKey,
          'environment': environment,
        },
        if (refresh) 'refresh': true,
      });
      if (!mounted || rev != revision) return;
      final models = jsonRows(data['models']);
      setState(() {
        catalog = data;
        modelId = textValue(
          data['currentModel'] ??
              models.where((r) => r['isDefault'] == true).firstOrNull?['id'],
        );
        if (modelId.isNotEmpty &&
            !models.any((r) => r['id'] == modelId) &&
            caps['manualModels'] == true) {
          manualModel.text = modelId;
          modelId = '__manual__';
        }
        effort = textValue(
          data['currentEffort'] ?? selectedModel['defaultEffort'],
        );
      });
    } catch (e) {
      if (mounted && rev == revision) setState(() => error = e);
    } finally {
      if (mounted && rev == revision) setState(() => loading = false);
    }
  }

  Future<void> browse() async {
    if (env.isEmpty) return;
    final path = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => ProjectDirectoryPage(
          scope: scope,
          environment: env,
          initialPath: textValue(project['cwd']),
        ),
      ),
    );
    if (path == null || !mounted) return;
    try {
      final result = await scope.write(GatewayCommand.registerProject, {
        'path': path,
        'createDirectory': false,
        if (codex) ...{
          'host': env['host'],
          'kind': env['type'] ?? 'desktop',
        } else ...{
          'environment': environment,
        },
      });
      final row = jsonObject(result['project']);
      final value = await scope.read(GatewayResource.projects);
      if (!mounted) return;
      setState(() {
        projects = value;
        projectKey = textValue(row['key']);
      });
      await loadModels();
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  Future<void> create() async {
    if (saving || loading || project.isEmpty || title.text.trim().isEmpty) {
      return;
    }
    final requiresMessage =
        projects?['createRequiresMessage'] == true ||
        project['createRequiresMessage'] == true ||
        env['createRequiresMessage'] == true;
    if (requiresMessage && message.text.trim().isEmpty) {
      setState(
        () => error = words(context, '请填写首条消息', 'Enter an opening message'),
      );
      return;
    }
    final options = <String, Object?>{
      'managementIdentity': scope.identities[true],
      if (codex)
        'kind': textValue(project['type'] ?? env['type'] ?? 'desktop')
      else if (environment.isNotEmpty)
        'environment': environment,
    };
    if (projects?['createModels'] == true) {
      final id = modelId == '__manual__' ? manualModel.text.trim() : modelId;
      final chosenEffort = effort == '__manual__'
          ? manualEffort.text.trim()
          : effort;
      if (id.isEmpty ||
          jsonObject(catalog?['cache'])['identity'] == null ||
          (selectedModel['efforts'] as List? ?? []).isNotEmpty &&
              chosenEffort.isEmpty) {
        setState(
          () => error = words(
            context,
            '请选择有效的模型与思考强度',
            'Select a valid model and reasoning effort',
          ),
        );
        return;
      }
      options.addAll({
        'model': id,
        'modelCatalogIdentity': jsonObject(catalog?['cache'])['identity'],
        if (modelId == '__manual__') 'manualModel': true,
        if (chosenEffort.isNotEmpty) 'effort': chosenEffort,
        if (effort == '__manual__') 'manualEffort': true,
      });
    }
    setState(() => saving = true);
    try {
      if (codex &&
              options['kind'] == 'desktop' &&
              project['independent'] != true ||
          !codex && env['surface'] == 'desktop') {
        final trust = await scope.write(GatewayCommand.trustProject, {
          codex ? 'key' : 'projectKey': projectKey,
          'confirmed': false,
        });
        if (trust['required'] == true || !codex && trust['trusted'] != true) {
          if (!mounted) return;
          if (!await confirmAction(
            context,
            words(context, '信任此工作区？', 'Trust this workspace?'),
            words(
              context,
              '原客户端会读取此目录的配置并可能运行其配置命令。仅信任来源已知的目录。',
              'The client reads this directory’s configuration and may run configured commands. Trust only directories from a known source.',
            ),
          )) {
            return;
          }
          await scope.write(GatewayCommand.trustProject, {
            codex ? 'key' : 'projectKey': projectKey,
            'confirmed': true,
            if (trust['confirmation'] != null)
              'confirmation': trust['confirmation'],
          });
        }
      }
      final offered = await scope.model.repository.projectsForEntry(
        scope.computer,
        scope.provider,
        scope.entry,
        textValue(project['host'] ?? 'local'),
      );
      final selected = offered.where((p) => p.key == projectKey).firstOrNull;
      if (selected == null) {
        throw StateError('Project changed; select it again');
      }
      scope.check();
      if (!mounted) return;
      await scope.model.createChat(
        selected,
        title.text.trim(),
        message.text,
        expectedConnection: scope.connection,
        options: options,
      );
      if (mounted && scope.model.error == null) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = jsonRows(projects?['projects'])
        .where((r) => environment.isEmpty || r['environment'] == environment)
        .toList();
    final models = jsonRows(catalog?['models']);
    final efforts = (selectedModel['efforts'] as List? ?? []).cast<String>();
    return AlertDialog(
      title: Text(words(context, '新聊天', 'New chat')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading || saving) const LinearProgressIndicator(),
              if (jsonRows(projects?['environments']).isNotEmpty)
                DropdownButtonFormField<String>(
                  key: ValueKey('env-$environment'),
                  initialValue: environment.isEmpty ? null : environment,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: words(context, '执行环境', 'Environment'),
                  ),
                  items: [
                    for (final row in jsonRows(projects?['environments']))
                      DropdownMenuItem(
                        value: textValue(row['key']),
                        child: Text(
                          textValue(row['name'] ?? row['key']),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: saving
                      ? null
                      : (v) {
                          setState(() {
                            environment = v!;
                            projectKey =
                                jsonRows(projects?['projects'])
                                    .where(
                                      (r) => r['environment'] == environment,
                                    )
                                    .firstOrNull?['key']
                                    ?.toString() ??
                                '';
                          });
                          loadModels();
                        },
                ),
              DropdownButtonFormField<String>(
                key: ValueKey('project-$projectKey'),
                initialValue: rows.any((r) => r['key'] == projectKey)
                    ? projectKey
                    : null,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: words(context, '项目', 'Project'),
                ),
                items: [
                  for (final row in rows)
                    DropdownMenuItem(
                      value: textValue(row['key']),
                      child: Text(
                        row['independent'] == true
                            ? words(context, '不选择项目', 'No project')
                            : textValue(row['name'] ?? row['key']),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: saving
                    ? null
                    : (v) {
                        setState(() => projectKey = v!);
                        loadModels();
                      },
              ),
              if (env['canBrowse'] != false && env.isNotEmpty)
                TextButton.icon(
                  onPressed: saving ? null : browse,
                  icon: const Icon(Icons.folder_open),
                  label: Text(
                    words(
                      context,
                      '浏览并登记目录',
                      'Browse and register a directory',
                    ),
                  ),
                ),
              if (projects?['createModels'] == true) ...[
                DropdownButtonFormField<String>(
                  key: ValueKey('model-$modelId-${catalog.hashCode}'),
                  initialValue:
                      models.any((r) => r['id'] == modelId) ||
                          modelId == '__manual__'
                      ? modelId
                      : null,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: words(context, '模型', 'Model'),
                  ),
                  items: [
                    for (final row in models)
                      DropdownMenuItem(
                        value: textValue(row['id']),
                        child: Text(
                          textValue(row['name'] ?? row['id']),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (caps['manualModels'] == true)
                      DropdownMenuItem(
                        value: '__manual__',
                        child: Text(words(context, '手动输入', 'Manual')),
                      ),
                  ],
                  onChanged: saving
                      ? null
                      : (v) => setState(() {
                          modelId = v!;
                          effort = textValue(selectedModel['defaultEffort']);
                        }),
                ),
                if (modelId == '__manual__')
                  TextField(
                    controller: manualModel,
                    maxLength: 300,
                    decoration: InputDecoration(
                      labelText: words(context, '模型名称', 'Model name'),
                    ),
                  ),
                if (efforts.isNotEmpty || caps['manualEffort'] == true)
                  DropdownButtonFormField<String>(
                    key: ValueKey('effort-$modelId-$effort'),
                    initialValue:
                        efforts.contains(effort) || effort == '__manual__'
                        ? effort
                        : null,
                    decoration: InputDecoration(
                      labelText: words(context, '思考强度', 'Reasoning effort'),
                    ),
                    items: [
                      for (final value in efforts)
                        DropdownMenuItem(value: value, child: Text(value)),
                      if (caps['manualEffort'] == true)
                        DropdownMenuItem(
                          value: '__manual__',
                          child: Text(words(context, '手动输入', 'Manual')),
                        ),
                    ],
                    onChanged: saving
                        ? null
                        : (v) => setState(() => effort = v!),
                  ),
                if (effort == '__manual__')
                  TextField(controller: manualEffort, maxLength: 64),
                TextButton(
                  onPressed: loading || saving
                      ? null
                      : () => loadModels(refresh: true),
                  child: Text(words(context, '刷新模型', 'Refresh models')),
                ),
              ],
              TextField(
                controller: title,
                maxLength: 120,
                decoration: InputDecoration(
                  labelText: words(context, '聊天名称', 'Title'),
                ),
              ),
              if (!codex)
                TextField(
                  controller: message,
                  minLines: 2,
                  maxLines: 5,
                  maxLength: 100000,
                  decoration: InputDecoration(
                    labelText: words(context, '首条消息', 'Opening message'),
                  ),
                ),
              if (error != null) SelectableText(businessError(context, error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: Text(words(context, '取消', 'Cancel')),
        ),
        FilledButton(
          onPressed: saving || loading ? null : create,
          child: Text(words(context, '创建', 'Create')),
        ),
      ],
    );
  }
}

class ProjectDirectoryPage extends StatefulWidget {
  const ProjectDirectoryPage({
    super.key,
    required this.scope,
    required this.environment,
    this.initialPath = '',
  });
  final GatewayBusiness scope;
  final Json environment;
  final String initialPath;
  @override
  State<ProjectDirectoryPage> createState() => _ProjectDirectoryState();
}

class _ProjectDirectoryState extends State<ProjectDirectoryPage> {
  Json? data;
  Object? error;
  bool hidden = false, busy = false;
  late final path = TextEditingController(text: widget.initialPath);
  @override
  void initState() {
    super.initState();
    load(widget.initialPath.isEmpty ? null : widget.initialPath);
  }

  @override
  void dispose() {
    path.dispose();
    super.dispose();
  }

  Future<void> load(String? value, {String? name}) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final result = await widget.scope.write(GatewayCommand.browseProjects, {
        if (widget.scope.provider == Provider.codex)
          'host': widget.environment['host']
        else
          'environment': widget.environment['key'],
        'path': value,
        'hidden': hidden,
        'name': name,
        'identity': name == null ? null : data?['identity'],
      });
      if (mounted) {
        setState(() {
          data = result;
          path.text = textValue(result['path']);
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(words(context, '选择目录', 'Choose directory')),
      actions: [
        IconButton(
          onPressed: busy
              ? null
              : () async {
                  final name = await promptText(
                    context,
                    words(context, '新文件夹名称', 'New folder name'),
                  );
                  if (name?.trim().isNotEmpty == true) {
                    await load(path.text, name: name!.trim());
                  }
                },
          icon: const Icon(Icons.create_new_folder_outlined),
        ),
        IconButton(
          onPressed: busy
              ? null
              : () {
                  hidden = !hidden;
                  load(path.text);
                },
          icon: Icon(hidden ? Icons.visibility : Icons.visibility_off),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: path,
            decoration: InputDecoration(
              labelText: words(context, '目录路径', 'Directory path'),
            ),
            onSubmitted: busy ? null : load,
          ),
        ),
        if (busy) const LinearProgressIndicator(),
        if (error != null) Text(businessError(context, error)),
        Expanded(
          child: ListView(
            children: [
              if (data?['parent'] != null)
                ListTile(
                  leading: const Icon(Icons.arrow_upward),
                  title: const Text('..'),
                  onTap: busy ? null : () => load(textValue(data!['parent'])),
                ),
              for (final row in [
                ...jsonRows(data?['roots']),
                ...jsonRows(data?['directories']),
              ])
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(textValue(row['name'] ?? row['path'])),
                  onTap: busy ? null : () => load(textValue(row['path'])),
                ),
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: busy || data?['path'] == null
                  ? null
                  : () => Navigator.pop(context, textValue(data!['path'])),
              child: Text(words(context, '选择此目录', 'Choose this directory')),
            ),
          ),
        ),
      ],
    ),
  );
}
