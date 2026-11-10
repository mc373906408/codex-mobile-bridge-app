import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'common.dart';

String isolatedPreviewHtml(
  String content, {
  String? renderer,
  String nonce = '',
}) {
  const escape = HtmlEscape(HtmlEscapeMode.attribute);
  final script = renderer == null ? "'none'" : "'nonce-$nonce'";
  final policy =
      "default-src 'none'; script-src $script; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; media-src 'none'; object-src 'none'; frame-src about:; base-uri 'none'; form-action 'none'";
  final body = renderer == null
      ? '<iframe sandbox="" allow="camera \'none\'; microphone \'none\'; geolocation \'none\'; clipboard-read \'none\'; clipboard-write \'none\'" style="border:0;width:100%;height:100vh" srcdoc="${escape.convert(content)}"></iframe>'
      : '<pre class="mermaid">${escape.convert(content)}</pre><script nonce="$nonce">${renderer.replaceAll('</script', r'<\/script')}</script><script nonce="$nonce">mermaid.initialize({startOnLoad:true,securityLevel:"strict",maxTextSize:200000,flowchart:{htmlLabels:false},secure:["securityLevel","startOnLoad","maxTextSize"]});</script>';
  return '<!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="${escape.convert(policy)}"><meta name="referrer" content="no-referrer"><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{margin:0;padding:8px;font-family:system-ui}svg{max-width:100%;height:auto}</style></head><body>$body</body></html>';
}

class IsolatedContentPreview extends StatefulWidget {
  const IsolatedContentPreview({
    super.key,
    required this.content,
    this.mermaid = false,
  });
  final String content;
  final bool mermaid;
  @override
  State<IsolatedContentPreview> createState() => _IsolatedContentPreviewState();
}

class _IsolatedContentPreviewState extends State<IsolatedContentPreview> {
  WebViewController? controller;
  Object? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final renderer = widget.mermaid
          ? await rootBundle.loadString('assets/preview/mermaid/mermaid.min.js')
          : null;
      final nonce = base64UrlEncode(
        List.generate(24, (_) => Random.secure().nextInt(256)),
      );
      final next = WebViewController(
        onPermissionRequest: (request) => request.deny(),
      );
      await next.setJavaScriptMode(
        widget.mermaid ? JavaScriptMode.unrestricted : JavaScriptMode.disabled,
      );
      await next.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (_) => NavigationDecision.prevent,
        ),
      );
      await next.loadHtmlString(
        isolatedPreviewHtml(widget.content, renderer: renderer, nonce: nonce),
      );
      if (mounted) setState(() => controller = next);
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  @override
  Widget build(BuildContext context) => controller == null
      ? BusinessLoading(error: error, retry: load)
      : WebViewWidget(controller: controller!);
}

class SourcePreviewPage extends StatefulWidget {
  const SourcePreviewPage({
    super.key,
    required this.title,
    required this.text,
    this.line = 1,
    this.onReference,
  });
  final String title, text;
  final int line;
  final void Function(int line)? onReference;
  @override
  State<SourcePreviewPage> createState() => _SourcePreviewPageState();
}

class _SourcePreviewPageState extends State<SourcePreviewPage> {
  final scroll = ScrollController();
  bool rendered = true;
  int selectedLine = 1;
  @override
  void initState() {
    super.initState();
    selectedLine = widget.line;
    if (widget.line > 1) rendered = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) jumpToLine(selectedLine);
    });
  }

  double get rowHeight => MediaQuery.textScalerOf(context).scale(13) * 1.5 + 4;
  void jumpToLine(int line) {
    if (scroll.hasClients) {
      scroll.jumpTo(
        ((line - 1) * rowHeight).clamp(0, scroll.position.maxScrollExtent),
      );
    }
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final extension = widget.title.split('.').last.toLowerCase();
    final rich = [
      'md',
      'markdown',
      'html',
      'htm',
      'mmd',
      'mermaid',
    ].contains(extension);
    final lines = widget.text.split('\n');
    Widget body;
    if (rendered && ['html', 'htm', 'mmd', 'mermaid'].contains(extension)) {
      body = IsolatedContentPreview(
        content: widget.text,
        mermaid: ['mmd', 'mermaid'].contains(extension),
      );
    } else if (rendered && ['md', 'markdown'].contains(extension)) {
      body = Markdown(
        data: widget.text,
        selectable: true,
        imageBuilder: (_, title, alt) =>
            Text(alt ?? words(context, '外部图片已阻止', 'External image blocked')),
        onTapLink: (_, href, _) {
          if (href != null) Clipboard.setData(ClipboardData(text: href));
        },
      );
    } else {
      final language =
          {
            'py': 'python',
            'js': 'javascript',
            'ts': 'typescript',
            'rs': 'rust',
            'sh': 'bash',
            'yml': 'yaml',
            'h': 'cpp',
            'kt': 'kotlin',
          }[extension] ??
          extension;
      body = ListView.builder(
        controller: scroll,
        itemExtent: rowHeight,
        itemCount: lines.length,
        itemBuilder: (_, index) => InkWell(
          onTap: () => setState(() => selectedLine = index + 1),
          child: Container(
            color: selectedLine == index + 1
                ? Theme.of(context).colorScheme.secondaryContainer
                : null,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 54,
                  child: Text(
                    '${index + 1}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontFamily: 'PlexMono',
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: HighlightView(
                      lines[index].isEmpty ? ' ' : lines[index],
                      padding: EdgeInsets.zero,
                      language: language,
                      theme: Theme.of(context).brightness == Brightness.dark
                          ? atomOneDarkTheme
                          : githubTheme,
                      textStyle: const TextStyle(
                        fontFamily: 'PlexMono',
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (rich)
            IconButton(
              tooltip: words(context, '切换源码与预览', 'Toggle source and preview'),
              icon: const Icon(Icons.code),
              onPressed: () => setState(() => rendered = !rendered),
            ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: words(context, '完整复制', 'Copy all'),
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: widget.text)),
          ),
          IconButton(
            icon: const Icon(Icons.format_list_numbered),
            tooltip: words(context, '定位行号', 'Go to line'),
            onPressed: () async {
              final result = await promptText(
                context,
                words(context, '行号', 'Line number'),
                initial: '$selectedLine',
              );
              final line = int.tryParse(result ?? '');
              if (!mounted || line == null || line < 1 || line > lines.length) {
                return;
              }
              setState(() {
                rendered = false;
                selectedLine = line;
              });
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) jumpToLine(line);
              });
            },
          ),
          if (widget.onReference != null)
            IconButton(
              icon: const Icon(Icons.add_comment_outlined),
              tooltip: words(context, '引用到草稿', 'Reference in draft'),
              onPressed: () => widget.onReference!(selectedLine),
            ),
        ],
      ),
      body: body,
    );
  }
}
