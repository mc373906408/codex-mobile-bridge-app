import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'common.dart';

/// Bounded, literal directive parser; malformed attributes remain ordinary text.
Json? readOutputDirective(String source, int start) {
  final text = source.substring(start, (start + 65536).clamp(0, source.length));
  final prefix = RegExp(
    r'^(::code-comment\{|:codex-file-citation\{|:codex-followup\[([^\]\n]+)\]\{)',
  ).firstMatch(text);
  if (prefix == null) return null;
  final kind = text.startsWith('::')
      ? 'comment'
      : text.startsWith(':codex-file-')
      ? 'file'
      : 'followup';
  var cursor = prefix.end;
  final fields = <String, dynamic>{};
  while (cursor < text.length) {
    while (cursor < text.length && text[cursor].trim().isEmpty) {
      cursor++;
    }
    if (cursor >= text.length) return null;
    if (text[cursor] == '}') {
      final allowed = kind == 'comment'
          ? ['title', 'body', 'file', 'start', 'end', 'priority']
          : kind == 'file'
          ? ['path', 'artifact_kind', 'purpose']
          : ['prompt'];
      final required = kind == 'comment'
          ? ['title', 'body', 'file']
          : kind == 'file'
          ? ['path']
          : ['prompt'];
      if (fields.keys.any((key) => !allowed.contains(key)) ||
          required.any(
            (key) => fields[key] is! String || (fields[key] as String).isEmpty,
          )) {
        return null;
      }
      if (kind == 'file' && fields.values.any((value) => value is! String)) {
        return null;
      }
      for (final key in ['start', 'end', 'priority']) {
        if (fields.containsKey(key) &&
            (fields[key] is! int ||
                fields[key] < (key == 'priority' ? 0 : 1) ||
                fields[key] > (key == 'priority' ? 3 : 1000000))) {
          return null;
        }
      }
      if (fields['end'] != null &&
          (fields['start'] == null || fields['end'] < fields['start'])) {
        return null;
      }
      return {
        'kind': kind,
        'label': prefix.group(2),
        'attributes': fields,
        'source': text.substring(0, cursor + 1),
        'end': start + cursor + 1,
      };
    }
    final key = RegExp(r'([a-z_]+)=').matchAsPrefix(text, cursor);
    if (key == null || fields.containsKey(key.group(1))) return null;
    cursor = key.end;
    if (cursor >= text.length) return null;
    Object value;
    if (text[cursor] == '"') {
      cursor++;
      final buffer = StringBuffer();
      var closed = false;
      while (cursor < text.length) {
        final char = text[cursor++];
        if (char == '"') {
          closed = true;
          break;
        }
        if (char == r'\') {
          if (cursor >= text.length) return null;
          final next = text[cursor++];
          buffer.write(next == '"' || next == r'\' ? next : '$char$next');
        } else {
          buffer.write(char);
        }
      }
      if (!closed) return null;
      value = buffer.toString();
    } else {
      final number = RegExp(r'\d+').matchAsPrefix(text, cursor);
      if (number == null) return null;
      final parsed = int.tryParse(number.group(0)!);
      if (parsed == null) return null;
      value = parsed;
      cursor = number.end;
    }
    fields[key.group(1)!] = value;
    if (cursor < text.length &&
        text[cursor] != '}' &&
        text[cursor].trim().isNotEmpty) {
      return null;
    }
  }
  return null;
}

class OutputDirectiveSyntax extends md.InlineSyntax {
  OutputDirectiveSyntax()
    : super(
        r'::code-comment\{|:codex-file-citation\{|:codex-followup\[[^\]\n]+\]\{',
        startCharacter: 58,
      );
  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final start = startMatchPos ?? parser.pos;
    if (parser.source.codeUnitAt(start) != 58) return false;
    final value = readOutputDirective(parser.source, start);
    if (value == null) return false;
    parser.writeText();
    final element = md.Element.empty('bridge-directive');
    element.attributes['data'] = jsonEncode(value);
    parser.addNode(element);
    parser.consume((value['end'] as int) - start);
    return true;
  }

  @override
  bool onMatch(md.InlineParser parser, Match match) => false;
}

class OutputDirectiveBuilder extends MarkdownElementBuilder {
  OutputDirectiveBuilder({this.onPrompt, this.onFile});
  final void Function(String)? onPrompt;
  final void Function(String, int)? onFile;
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final data = jsonObject(element.attributes['data']),
        attrs = jsonObject(data['attributes']);
    if (data['kind'] == 'followup') {
      return OutlinedButton.icon(
        onPressed: onPrompt == null
            ? null
            : () => onPrompt!(textValue(attrs['prompt'])),
        icon: const Icon(Icons.edit_note),
        label: Text(textValue(data['label'])),
      );
    }
    final path = textValue(attrs[data['kind'] == 'file' ? 'path' : 'file']);
    final line = attrs['start'] as int? ?? 1;
    final location = TextButton.icon(
      onPressed: onFile == null ? null : () => onFile!(path, line),
      icon: const Icon(Icons.description_outlined),
      label: Text(
        '$path${attrs['start'] == null ? '' : ':$line${attrs['end'] == null ? '' : '–${attrs['end']}'}'}',
      ),
    );
    if (data['kind'] == 'file') return location;
    final title = textValue(attrs['title']);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${attrs['priority'] != null && !title.startsWith('[P${attrs['priority']}]') ? '[P${attrs['priority']}] ' : ''}$title',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            SelectableText(textValue(attrs['body'])),
            location,
            TextButton.icon(
              onPressed: () => Clipboard.setData(
                ClipboardData(text: textValue(data['source'])),
              ),
              icon: const Icon(Icons.copy),
              label: Text(words(context, '复制批注源码', 'Copy comment source')),
            ),
          ],
        ),
      ),
    );
  }
}
