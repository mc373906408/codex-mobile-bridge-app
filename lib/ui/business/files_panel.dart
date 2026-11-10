import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/bridge_repository.dart';
import '../../data/workspace_download.dart';
import 'common.dart';
import 'content_preview.dart';
import 'appearance_settings.dart';

class FilesPanel extends StatefulWidget {
  const FilesPanel({
    super.key,
    required this.scope,
    this.initialFile,
    this.initialLine = 1,
  });
  final SessionBusiness scope;
  final String? initialFile;
  final int initialLine;
  @override
  State<FilesPanel> createState() => _FilesPanelState();
}

class _FilesPanelState extends State<FilesPanel>
    with AutomaticKeepAliveClientMixin {
  String path = '', search = '';
  bool hidden = false, loading = false, downloading = false, uploading = false;
  bool get transferring => downloading || uploading;
  int received = 0, total = 0, generation = 0;
  int? nextOffset;
  List<Json> entries = [];
  Object? error;
  @override
  bool get wantKeepAlive => true;
  @override
  void initState() {
    super.initState();
    load();
    if (widget.initialFile != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        var target = widget.initialFile!.replaceAll('\\', '/');
        final root = widget.scope.snapshot.cwd
            .replaceAll('\\', '/')
            .replaceFirst(RegExp(r'/+$'), '');
        if (target.toLowerCase().startsWith('${root.toLowerCase()}/')) {
          target = target.substring(root.length + 1);
        }
        open({
          'path': target,
          'name': target.split('/').last,
          'kind': 'file',
          'line': widget.initialLine,
        });
      });
    }
  }

  Future<void> load({bool more = false}) async {
    final request = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final data = await widget.scope.read(SessionResource.files, {
        'path': path,
        'hidden': hidden,
        'search': search,
        'offset': more ? nextOffset ?? 0 : 0,
      });
      if (!mounted || generation != request) return;
      setState(() {
        entries = [if (more) ...entries, ...jsonRows(data['entries'])];
        nextOffset = data['nextOffset'] as int?;
      });
    } catch (e) {
      if (mounted && generation == request) setState(() => error = e);
    } finally {
      if (mounted && generation == request) setState(() => loading = false);
    }
  }

  Future<File> download(
    String target,
    bool archive, {
    bool restart = false,
  }) async {
    setState(() {
      downloading = true;
      received = total = 0;
    });
    try {
      final file = await downloadWorkspace(
        widget.scope.model.repository,
        widget.scope.snapshot,
        target,
        archive,
        restart: restart,
        active: () => mounted && downloading && widget.scope.current,
        progress: (a, b) {
          if (mounted) {
            setState(() {
              received = a;
              total = b;
            });
          }
        },
      );
      await widget.scope.verify();
      return file;
    } finally {
      if (mounted) setState(() => downloading = false);
    }
  }

  Future<void> reference(String target, int line) async {
    final model = widget.scope.model;
    if (model.selected != widget.scope.session) {
      showFailure(
        context,
        words(
          context,
          '请先打开此聊天再引用文件',
          'Open this chat before adding a reference',
        ),
      );
      return;
    }
    try {
      await model.addFileReference(target, line);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(words(context, '已加入聊天草稿', 'Added to the chat draft')),
          ),
        );
      }
    } catch (error) {
      if (mounted) showFailure(context, error);
    }
  }

  Future<void> open(Json row) async {
    if (row['kind'] == 'directory') {
      setState(() {
        path = textValue(row['path']);
        search = '';
      });
      await load();
      return;
    }
    try {
      final target = textValue(row['path']);
      if (target.toLowerCase().endsWith('.pdf')) {
        final file = await download(target, false);
        if (mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                appBar: AppBar(title: Text(textValue(row['name']))),
                body: PdfViewer.file(file.path),
              ),
            ),
          );
        }
        return;
      }
      final data = await widget.scope.read(SessionResource.filePreview, {
        'path': target,
      });
      if (!mounted) return;
      if (data['kind'] == 'image') {
        final bytes = base64Decode(data['data'] as String);
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              appBar: AppBar(title: Text(textValue(row['name']))),
              body: Center(
                child: InteractiveViewer(
                  maxScale: 8,
                  child: Image.memory(bytes),
                ),
              ),
            ),
          ),
        );
      } else if (data['kind'] == 'text') {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => SourcePreviewPage(
              title: target,
              text: textValue(data['text']),
              line: row['line'] as int? ?? 1,
              onReference: (line) => reference(target, line),
            ),
          ),
        );
      } else {
        showFailure(
          context,
          data['message'] ??
              words(
                context,
                '此文件不支持预览，可下载后打开',
                'Download this file to open it',
              ),
        );
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  Future<void> actions(Json row) async {
    final target = textValue(row['path']);
    final choice = await chooseValue(context, textValue(row['name']), {
      'download': words(context, '下载 / 续传后分享', 'Download / resume and share'),
      'save': words(
        context,
        '下载 / 续传后保存到文件',
        'Download / resume and save to Files',
      ),
      'restart': words(context, '重新下载', 'Restart download'),
      'reference': words(context, '引用到草稿', 'Reference in draft'),
      'copyPath': words(context, '复制绝对路径', 'Copy absolute path'),
    });
    if (choice == null || !mounted) return;
    if (choice == 'reference') {
      reference(target, 1);
      return;
    }
    try {
      if (choice == 'copyPath') {
        final info = await widget.scope.read(SessionResource.fileInfo, {
          'path': target,
        });
        await Clipboard.setData(
          ClipboardData(text: textValue(info['absolutePath'])),
        );
        return;
      }
      final file = await download(
        target,
        row['kind'] == 'directory',
        restart: choice == 'restart',
      );
      if (!mounted) return;
      if (choice == 'save') {
        final saved = await const MethodChannel('dev.waken.bridge_mobile/files')
            .invokeMethod<bool>('save', {'path': file.path});
        if (mounted && saved == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(words(context, '文件已保存', 'File saved'))),
          );
        }
        return;
      }
      final box = context.findRenderObject() as RenderBox;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  Future<void> upload() async {
    try {
      final file = await FilePicker.pickFile();
      if (file == null || !mounted) return;
      if ((file.lengthSync() ?? 0) > 20 * 1024 * 1024) {
        throw StateError('Each upload must be at most 20 MiB');
      }
      final destination = path.isEmpty ? file.name : '$path/${file.name}';
      if (!await confirmAction(
        context,
        words(context, '上传到电脑', 'Upload to computer'),
        destination,
      )) {
        return;
      }
      if (!mounted) return;
      setState(() => uploading = true);
      await widget.scope.verify();
      final builder = BytesBuilder(copy: false);
      await for (final chunk in file.readAsByteStream()) {
        if (builder.length + chunk.length > 20 * 1024 * 1024) {
          throw StateError('Each upload must be at most 20 MiB');
        }
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      final reply = await widget.scope.model.repository.uploadWorkspace(
        widget.scope.snapshot,
        widget.scope.model.repository.newId(),
        destination,
        bytes,
      );
      if (reply.outcome.kind != OutcomeKind.accepted) {
        throw StateError(reply.outcome.message);
      }
      await load();
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: words(context, '上级目录', 'Parent folder'),
                    onPressed: path.isEmpty
                        ? null
                        : () {
                            setState(
                              () => path = path.contains('/')
                                  ? path.substring(0, path.lastIndexOf('/'))
                                  : '',
                            );
                            load();
                          },
                    icon: const Icon(Icons.arrow_upward),
                  ),
                  Expanded(
                    child: Text(
                      path.isEmpty ? widget.scope.snapshot.cwd : path,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    onPressed: transferring
                        ? null
                        : () => actions({
                            'path': path,
                            'name': path.isEmpty
                                ? widget.scope.snapshot.cwd
                                : path,
                            'kind': 'directory',
                          }),
                    tooltip: words(context, '当前目录操作', 'Current folder actions'),
                    icon: const Icon(Icons.more_vert),
                  ),
                  IconButton(
                    onPressed: transferring ? null : upload,
                    tooltip: words(context, '上传文件', 'Upload file'),
                    icon: const Icon(Icons.upload_file),
                  ),
                  IconButton(
                    onPressed: () {
                      setState(() => hidden = !hidden);
                      load();
                    },
                    tooltip: words(context, '隐藏文件', 'Hidden files'),
                    icon: Icon(
                      hidden ? Icons.visibility : Icons.visibility_off,
                    ),
                  ),
                  IconButton(
                    onPressed: loading ? null : load,
                    tooltip: words(context, '刷新', 'Refresh'),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              TextFormField(
                key: ValueKey(path),
                initialValue: search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: words(context, '搜索当前目录', 'Search this folder'),
                ),
                onFieldSubmitted: (value) {
                  search = value;
                  load();
                },
              ),
            ],
          ),
        ),
        if (uploading)
          ListTile(
            title: const LinearProgressIndicator(),
            subtitle: Text(words(context, '正在上传文件…', 'Uploading file…')),
          ),
        if (downloading)
          ListTile(
            title: LinearProgressIndicator(
              value: total > 0 ? received / total : null,
            ),
            subtitle: Text('$received / $total'),
            trailing: IconButton(
              onPressed: () => setState(() => downloading = false),
              icon: const Icon(Icons.pause),
            ),
          ),
        if (loading) const LinearProgressIndicator(),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(businessError(context, error)),
          ),
        Expanded(
          child: ListView.builder(
            key: PageStorageKey(('files', widget.scope.session, path)),
            itemCount: entries.length + (nextOffset != null ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == entries.length) {
                return TextButton(
                  onPressed: loading ? null : () => load(more: true),
                  child: Text(words(context, '加载更多', 'Load more')),
                );
              }
              final row = entries[index];
              return ListTile(
                enabled: row['kind'] != 'blocked',
                leading:
                    ChatAppearanceScope.of(context)
                            .show('showFileThumbnails') &&
                        row['kind'] == 'file' &&
                        RegExp(
                          r'\.(png|jpg|jpeg|gif|webp)$',
                          caseSensitive: false,
                        ).hasMatch(textValue(row['name']))
                    ? _FileThumbnail(
                        key: ValueKey((generation, row['path'])),
                        scope: widget.scope,
                        path: textValue(row['path']),
                      )
                    : Icon(
                        row['kind'] == 'directory'
                            ? Icons.folder_outlined
                            : Icons.insert_drive_file_outlined,
                      ),
                title: Text(textValue(row['name'])),
                subtitle: row['size'] == null ? null : Text('${row['size']} B'),
                onTap: transferring ? null : () => open(row),
                onLongPress: () => actions(row),
                trailing: IconButton(
                  icon: const Icon(Icons.more_horiz),
                  onPressed: transferring ? null : () => actions(row),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FileThumbnail extends StatefulWidget {
  const _FileThumbnail({super.key, required this.scope, required this.path});
  final SessionBusiness scope;
  final String path;
  @override
  State<_FileThumbnail> createState() => _FileThumbnailState();
}

class _FileThumbnailState extends State<_FileThumbnail> {
  late final Future<Uint8List?> image = load();
  Future<Uint8List?> load() async {
    try {
      final value = await widget.scope.read(SessionResource.filePreview, {
        'path': widget.path,
      });
      if (value['kind'] == 'image' && value['data'] is String) {
        return base64Decode(value['data']);
      }
    } catch (_) {
      /* Unavailable previews retain the file action. */
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 40,
    height: 40,
    child: FutureBuilder<Uint8List?>(
      future: image,
      builder: (context, state) => state.data == null
          ? const Icon(Icons.image_outlined)
          : Image.memory(
              state.data!,
              cacheWidth: 120,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.image_not_supported_outlined),
            ),
    ),
  );
}
