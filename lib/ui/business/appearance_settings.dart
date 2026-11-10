import 'package:flutter/material.dart';

import 'common.dart';

class ChatAppearance {
  const ChatAppearance(this.values);
  final Map<String, dynamic> values;
  bool show(String key) => values[key] != false;
  double get fontSize =>
      ((values['messageSize'] as num?)?.toDouble() ?? 16).clamp(10, 32);
  double get codeSize =>
      ((values['codeSize'] as num?)?.toDouble() ?? 13).clamp(8, 28);
  String get density => const ['compact', 'relaxed'].contains(values['density'])
      ? values['density']
      : 'standard';
  String? get fontFamily =>
      const ['PlexSans', 'PlexMono'].contains(values['fontFamily'])
      ? values['fontFamily']
      : null;
  String get codeFamily =>
      values['codeFamily'] == 'system' ? 'monospace' : 'PlexMono';
  Color? get accent {
    final value = values['accent'];
    return value is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)
        ? Color(0xff000000 | int.parse(value.substring(1), radix: 16))
        : null;
  }

  double get messageGap => switch (density) {
    'compact' => 10,
    'relaxed' => 26,
    _ => 18,
  };
  bool visible(String role, Map metadata) {
    if (role == 'user' || role == 'error') return true;
    if (role == 'reasoning' || metadata['kind'] == 'reasoning') {
      return show('showReasoning');
    }
    if (role == 'activity' || metadata['phase'] == 'commentary') {
      return show('showProcess');
    }
    return true;
  }

  ThemeData apply(ThemeData base) {
    final palette = accent == null
        ? base.colorScheme
        : ColorScheme.fromSeed(seedColor: accent!, brightness: base.brightness);
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: palette.primary,
        onPrimary: palette.onPrimary,
        primaryContainer: palette.primaryContainer,
        onPrimaryContainer: palette.onPrimaryContainer,
        secondary: palette.secondary,
      ),
      textTheme: fontFamily == null
          ? base.textTheme
          : base.textTheme.apply(fontFamily: fontFamily),
      visualDensity: switch (density) {
        'compact' => const VisualDensity(horizontal: -1, vertical: -1),
        'relaxed' => const VisualDensity(horizontal: 1, vertical: 1),
        _ => VisualDensity.standard,
      },
    );
  }
}

class ChatAppearanceScope extends InheritedWidget {
  const ChatAppearanceScope({
    super.key,
    required this.appearance,
    required super.child,
  });
  final ChatAppearance appearance;
  static ChatAppearance of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ChatAppearanceScope>()
          ?.appearance ??
      const ChatAppearance({});
  @override
  bool updateShouldNotify(ChatAppearanceScope oldWidget) =>
      oldWidget.appearance.values != appearance.values;
}

class AppearanceSettingsPage extends StatelessWidget {
  const AppearanceSettingsPage({super.key, required this.model});
  final BridgeViewModel model;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final appearance = ChatAppearance(model.presentation);
      return Scaffold(
        appBar: AppBar(title: Text(words(context, '聊天显示', 'Chat appearance'))),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final field in [
              (
                'messageSize',
                words(context, '正文字号', 'Message size'),
                appearance.fontSize,
                10.0,
                32.0,
              ),
              (
                'codeSize',
                words(context, '代码字号', 'Code size'),
                appearance.codeSize,
                8.0,
                28.0,
              ),
            ])
              ListTile(
                title: Text('${field.$2} · ${field.$3.round()}'),
                subtitle: Slider(
                  value: field.$3,
                  min: field.$4,
                  max: field.$5,
                  divisions: (field.$5 - field.$4).round(),
                  onChanged: (value) => model.setPresentation(field.$1, value),
                ),
              ),
            ListTile(
              title: Text(words(context, '正文字体', 'Message font')),
              subtitle: DropdownButton<String>(
                isExpanded: true,
                value: appearance.fontFamily ?? 'system',
                items: [
                  DropdownMenuItem(
                    value: 'system',
                    child: Text(words(context, '系统字体', 'System')),
                  ),
                  const DropdownMenuItem(
                    value: 'PlexSans',
                    child: Text('IBM Plex Sans'),
                  ),
                  const DropdownMenuItem(
                    value: 'PlexMono',
                    child: Text('IBM Plex Mono'),
                  ),
                ],
                onChanged: (value) =>
                    model.setPresentation('fontFamily', value),
              ),
            ),
            ListTile(
              title: Text(words(context, '代码字体', 'Code font')),
              subtitle: DropdownButton<String>(
                isExpanded: true,
                value: appearance.codeFamily == 'monospace'
                    ? 'system'
                    : 'PlexMono',
                items: [
                  DropdownMenuItem(
                    value: 'system',
                    child: Text(words(context, '系统等宽', 'System monospace')),
                  ),
                  const DropdownMenuItem(
                    value: 'PlexMono',
                    child: Text('IBM Plex Mono'),
                  ),
                ],
                onChanged: (value) =>
                    model.setPresentation('codeFamily', value),
              ),
            ),
            ListTile(
              title: Text(words(context, '显示密度', 'Density')),
              subtitle: DropdownButton<String>(
                isExpanded: true,
                value: appearance.density,
                items: [
                  for (final item in [
                    ('compact', '紧凑', 'Compact'),
                    ('standard', '标准', 'Standard'),
                    ('relaxed', '宽松', 'Relaxed'),
                  ])
                    DropdownMenuItem(
                      value: item.$1,
                      child: Text(words(context, item.$2, item.$3)),
                    ),
                ],
                onChanged: (value) => model.setPresentation('density', value),
              ),
            ),
            ListTile(
              title: Text(words(context, '强调色', 'Accent color')),
              subtitle: Wrap(
                spacing: 8,
                children: [
                  for (final color in [
                    '#007aff',
                    '#4664ed',
                    '#008568',
                    '#b23883',
                    '#b95500',
                  ])
                    IconButton(
                      tooltip: color,
                      onPressed: () => model.setPresentation('accent', color),
                      icon: Icon(
                        model.presentation['accent'] == color
                            ? Icons.check_circle
                            : Icons.circle,
                        color: Color(
                          0xff000000 | int.parse(color.substring(1), radix: 16),
                        ),
                      ),
                    ),
                  TextButton(
                    onPressed: () async {
                      final value = await promptText(
                        context,
                        words(
                          context,
                          '自定义颜色（#RRGGBB）',
                          'Custom color (#RRGGBB)',
                        ),
                        initial:
                            model.presentation['accent'] as String? ??
                            '#007aff',
                      );
                      if (value != null &&
                          RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
                        model.setPresentation('accent', value);
                      }
                    },
                    child: Text(words(context, '自定义', 'Custom')),
                  ),
                ],
              ),
            ),
            for (final item in [
              ('showReasoning', '思考内容', 'Reasoning'),
              ('showProcess', '执行过程', 'Process messages'),
              ('showToolImages', '工具截图', 'Tool images'),
              ('showActivity', '活动状态', 'Activity status'),
              ('showComputer', '聊天中的电脑信息', 'Computer in chat'),
              ('showFileThumbnails', '文件缩略图', 'File thumbnails'),
              ('showAccounts', '编码工具账号入口', 'Coding account entry'),
              ('showPushplus', 'PushPlus 通知入口', 'PushPlus entry'),
            ])
              SwitchListTile(
                value: appearance.show(item.$1),
                title: Text(words(context, item.$2, item.$3)),
                onChanged: (value) => model.setPresentation(item.$1, value),
              ),
            TextButton(
              onPressed: () {
                for (final key in [
                  'messageSize',
                  'codeSize',
                  'fontFamily',
                  'codeFamily',
                  'density',
                  'accent',
                  'showReasoning',
                  'showProcess',
                  'showToolImages',
                  'showActivity',
                  'showComputer',
                  'showFileThumbnails',
                  'showAccounts',
                  'showPushplus',
                ]) {
                  model.setPresentation(key, null);
                }
              },
              child: Text(words(context, '恢复显示默认值', 'Reset appearance')),
            ),
          ],
        ),
      );
    },
  );
}
