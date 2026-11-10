import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

import '../../data/bridge_repository.dart';
import 'common.dart';
import 'content_preview.dart';
import 'output_directives.dart';
import 'workspace_page.dart';
import 'appearance_settings.dart';

class RichMessageText extends StatelessWidget {
  const RichMessageText({
    super.key,
    required this.text,
    this.onLink,
    this.onPrompt,
    this.onFile,
  });
  final String text;
  final void Function(String)? onLink;
  final void Function(String)? onPrompt;
  final void Function(String, int)? onFile;
  @override
  Widget build(BuildContext context) => MarkdownBody(
    data: text,
    selectable: true,
    inlineSyntaxes: [OutputDirectiveSyntax(), _MathSyntax()],
    builders: {
      'code': _CodeBuilder(),
      'latex': _MathBuilder(),
      'bridge-directive': OutputDirectiveBuilder(
        onPrompt: onPrompt,
        onFile: onFile,
      ),
    },
    imageBuilder: (_, title, alt) => Text(
      '[${words(context, '外部图片已阻止', 'External image blocked')}: ${alt ?? ''}]',
    ),
    onTapLink: (_, href, _) {
      if (href != null) {
        if (onLink != null) {
          onLink!(href);
        } else {
          Clipboard.setData(ClipboardData(text: href));
        }
      }
    },
    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: Theme.of(context).textTheme.bodyLarge?.copyWith(
        height: 1.6,
        fontSize: ChatAppearanceScope.of(context).fontSize,
      ),
      code: TextStyle(
        fontFamily: ChatAppearanceScope.of(context).codeFamily,
        fontSize: ChatAppearanceScope.of(context).codeSize,
      ),
    ),
  );
}

class _MathSyntax extends md.InlineSyntax {
  _MathSyntax()
    : super(
        r'\$\$([\s\S]+?)\$\$|\$([^\$\n]+?)\$|\\\(([\s\S]+?)\\\)|\\\[([\s\S]+?)\\\]',
      );
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(
      md.Element.text(
        'latex',
        match.group(1) ??
            match.group(2) ??
            match.group(3) ??
            match.group(4) ??
            '',
      ),
    );
    return true;
  }
}

class _MathBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Math.tex(
      element.textContent,
      textStyle: parentStyle,
      onErrorFallback: (e) => SelectableText(element.textContent),
    ),
  );
}

class _CodeBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final language = (element.attributes['class'] ?? '').replaceFirst(
      'language-',
      '',
    );
    if (!element.textContent.contains('\n') && language.isEmpty) return null;
    if (language == 'mermaid') {
      return OutlinedButton.icon(
        icon: const Icon(Icons.account_tree_outlined),
        label: Text(words(context, '查看 Mermaid 图', 'View Mermaid diagram')),
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('Mermaid')),
              body: IsolatedContentPreview(
                content: element.textContent,
                mermaid: true,
              ),
            ),
          ),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(language),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.copy, size: 16),
                tooltip: words(context, '复制代码', 'Copy code'),
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: element.textContent)),
              ),
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: HighlightView(
              element.textContent,
              language: language.isEmpty ? 'plaintext' : language,
              theme: Theme.of(context).brightness == Brightness.dark
                  ? atomOneDarkTheme
                  : githubTheme,
              textStyle: TextStyle(
                fontFamily: ChatAppearanceScope.of(context).codeFamily,
                fontSize: ChatAppearanceScope.of(context).codeSize,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<String> fullMessageText(
  SessionBusiness scope,
  ChatMessage message,
  String epoch,
) async {
  if (!message.truncated || scope.session.provider != Provider.codex) {
    return [
      message.text,
      message.output,
    ].where((s) => s.isNotEmpty).join('\n\n');
  }
  final row = jsonObject(message.metadata);
  if (row['fileSummary'] != null) return message.text;
  final buffer = StringBuffer();
  var offset = 0;
  for (;;) {
    final data = await scope.read(SessionResource.messageDetail, {
      'key': '$epoch.${row['key'] ?? message.id}',
      'offset': offset,
      'version': row['version'],
    });
    if (data['version'] != row['version'] ||
        data['offset'] != offset ||
        data['key'] != (row['key'] ?? message.id) ||
        data['text'] is! String) {
      throw StateError('Message changed; reopen it');
    }
    buffer.write(data['text']);
    if (data['next'] == null) return buffer.toString();
    final next = data['next'];
    if (next is! int || next <= offset) {
      throw StateError('Invalid message continuation');
    }
    offset = next;
  }
}

Future<void> messageAction(
  BuildContext context,
  BridgeViewModel model,
  ChatMessage message,
  String action,
) async {
  final snapshot = model.snapshot;
  if (snapshot == null) return;
  final scope = SessionBusiness(model, snapshot),
      row = jsonObject(message.metadata),
      epoch = model.historyEpoch;
  try {
    if (action == 'copy' ||
        action == 'expand' ||
        action == 'quote' ||
        action == 'select-quote') {
      final text = await fullMessageText(scope, message, epoch);
      scope.check();
      if (model.selected != scope.session ||
          model.snapshot?.accountIdentity != snapshot.accountIdentity) {
        return;
      }
      if (action == 'copy') await Clipboard.setData(ClipboardData(text: text));
      if (action == 'quote') {
        model.addQuote(text, message.id);
      }
      if (action == 'select-quote' && context.mounted) {
        final selected = await Navigator.push<String>(
          context,
          MaterialPageRoute(builder: (_) => _QuoteSelectionPage(text: text)),
        );
        if (selected != null &&
            model.selected == scope.session &&
            model.snapshot?.accountIdentity == snapshot.accountIdentity) {
          model.addQuote(selected, message.id);
        }
      }
      if (action == 'expand' && context.mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              appBar: AppBar(
                title: Text(
                  message.title.isEmpty
                      ? words(context, '完整内容', 'Full message')
                      : message.title,
                ),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.copy),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: text)),
                  ),
                ],
              ),
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: RichMessageText(
                  text: text,
                  onPrompt: (prompt) {
                    if (model.selected == scope.session &&
                        model.snapshot?.accountIdentity ==
                            snapshot.accountIdentity) {
                      model.editDraft(
                        '${model.draftText}${model.draftText.isEmpty ? '' : '\n\n'}$prompt',
                      );
                    }
                  },
                  onFile: (path, line) => openMessageFile(
                    context,
                    model,
                    scope.session,
                    path,
                    line,
                  ),
                ),
              ),
            ),
          ),
        );
      }
      return;
    }
    String? text;
    final expected = snapshot;
    if (action != 'fork') {
      final original = await fullMessageText(scope, message, epoch);
      if (!context.mounted) return;
      text = await promptText(
        context,
        words(context, '编辑并重新发送', 'Edit and resend'),
        initial: original,
        multiline: true,
        description: words(
          context,
          '已执行的文件修改和命令不会撤销。',
          'Previously executed file changes and commands will not be undone.',
        ),
      );
      if (text == null) return;
    } else if (!await confirmAction(
      context,
      words(context, '从此消息创建分支？', 'Fork from this message?'),
      words(
        context,
        '新聊天保留截至此处的上下文，并共享当前工作目录。',
        'The new chat keeps context up to this point and shares the working directory.',
      ),
    )) {
      return;
    }
    if (model.selected != scope.session ||
        model.snapshot?.accountIdentity != expected.accountIdentity) {
      throw StateError('Chat or account changed');
    }
    final Json data;
    if (scope.session.provider == Provider.codex) {
      data = await scope.write(SessionCommand.messageAction, {
        'action': action,
        'key': '$epoch.${row['key'] ?? message.id}',
        'version': row['version'],
        'text': text,
      });
    } else {
      data = await scope.write(
        action == 'fork' ? SessionCommand.fork : SessionCommand.editMessage,
        {
          'messageId':
              row[action == 'fork' ? 'forkMessageId' : 'editMessageId'],
          'text': ?text,
        },
      );
    }
    final id = data['id'] ?? jsonObject(data['result'])['id'];
    if (action != 'edit' && id is String) {
      await model.openSession(
        SessionRef(
          computerId: scope.session.computerId,
          provider: scope.session.provider,
          entry: scope.session.entry,
          environment: textValue(data['host'] ?? scope.session.environment),
          id: id,
        ),
      );
      if (data['draft'] is String) {
        model.setDraftOption('pendingEdit', {
          'text': data['draft'],
          'source': data['source'],
        });
        model.reportError(
          'Fork created; the edit was not sent. Review and edit the last message.',
        );
      }
    } else {
      await model.openSession(scope.session);
    }
  } catch (e) {
    if (context.mounted) showFailure(context, e);
  } finally {
    scope.dispose();
  }
}

String prettyContent(Object? value) =>
    const JsonEncoder.withIndent('  ').convert(value);

class _QuoteSelectionPage extends StatefulWidget {
  const _QuoteSelectionPage({required this.text});
  final String text;
  @override
  State<_QuoteSelectionPage> createState() => _QuoteSelectionState();
}

class _QuoteSelectionState extends State<_QuoteSelectionPage> {
  TextSelection selection = const TextSelection.collapsed(offset: 0);
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(words(context, '选择要引用的文字', 'Select text to quote')),
      actions: [
        TextButton(
          onPressed: selection.isValid && !selection.isCollapsed
              ? () => Navigator.pop(context, selection.textInside(widget.text))
              : null,
          child: Text(words(context, '引用所选', 'Quote selection')),
        ),
      ],
    ),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: SelectableText(
        widget.text,
        style: Theme.of(context).textTheme.bodyLarge,
        onSelectionChanged: (value, _) => setState(() => selection = value),
      ),
    ),
  );
}

Future<void> openMessageFile(
  BuildContext context,
  BridgeViewModel model,
  SessionRef session,
  String path,
  int line,
) async {
  final snapshot = model.snapshot;
  if (snapshot == null || snapshot.session != session) return;
  final scope = SessionBusiness(model, snapshot);
  try {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            WorkspacePage(scope: scope, initialFile: path, initialLine: line),
      ),
    );
  } finally {
    scope.dispose();
  }
}
