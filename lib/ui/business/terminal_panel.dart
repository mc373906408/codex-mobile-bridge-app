import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../../data/bridge_repository.dart';
import 'common.dart';

class TerminalPanel extends StatefulWidget {
  const TerminalPanel({super.key, required this.scope});
  final SessionBusiness scope;
  @override
  State<TerminalPanel> createState() => _TerminalPanelState();
}

class _TerminalPanelState extends State<TerminalPanel>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  late final Terminal terminal;
  final input = TextEditingController();
  String id = '', status = '';
  int cursor = 0, cols = 80, rows = 24;
  bool running = false,
      commandMode = false,
      busy = false,
      polling = false,
      inputBlocked = false;
  Timer? timer, resizeTimer;
  Future<void> inputTail = Future<void>.value();
  String get handleKey => jsonEncode([
    widget.scope.model.sessionKey(widget.scope.session),
    widget.scope.snapshot.accountIdentity,
  ]);
  Future<void> saveHandle() => widget.scope.model.saveTerminalHandle(
    handleKey,
    id.isEmpty
        ? null
        : {'id': id, 'commandMode': commandMode, 'inputBlocked': inputBlocked},
  );
  @override
  bool get wantKeepAlive => true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    terminal = Terminal(
      maxLines: 10000,
      onOutput: sendInput,
      onResize: (w, h, _, _) {
        cols = w;
        rows = h;
        resizeTimer?.cancel();
        resizeTimer = Timer(const Duration(milliseconds: 200), resize);
      },
    );
    final handle = jsonObject(
      jsonObject(widget.scope.model.presentation['terminalHandles'])[handleKey],
    );
    id = textValue(handle['id']);
    commandMode = handle['commandMode'] == true;
    inputBlocked = handle['inputBlocked'] == true;
    inspect();
  }

  @override
  void dispose() {
    timer?.cancel();
    resizeTimer?.cancel();
    input.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    timer?.cancel();
    if (state == AppLifecycleState.resumed && id.isNotEmpty) {
      timer = Timer(const Duration(seconds: 1), () async {
        if (running) {
          schedule();
        } else {
          await inspect();
        }
      });
    }
  }

  Future<void> inspect() async {
    try {
      final info = await widget.scope.read(SessionResource.terminal, {
        'mode': 'pty',
      });
      if (mounted) {
        setState(() {
          if (id.isEmpty) commandMode = info['mode'] == 'command';
          status = textValue(info['shell'] ?? info['message']);
        });
        if (id.isNotEmpty) {
          final existing = id;
          final recovered = await widget.scope.read(SessionResource.terminal, {
            'id': existing,
            'mode': commandMode ? 'command' : 'pty',
            'after': 0,
            'waitMs': 0,
          });
          if (mounted && id == existing) {
            apply(recovered);
            schedule();
          }
        }
      }
    } catch (e) {
      if (mounted) setState(() => status = businessError(context, e));
    }
  }

  Future<void> start() async {
    if (busy || running) return;
    if (!await confirmAction(
      context,
      words(context, '在电脑上打开终端', 'Open terminal on computer'),
      widget.scope.snapshot.cwd,
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      // An unknown prior open is never implicitly replaced with another shell.
      if (id.isNotEmpty) {
        final recovered = await widget.scope.read(SessionResource.terminal, {
          'id': id,
          'mode': commandMode ? 'command' : 'pty',
          'after': cursor,
          'waitMs': 0,
        });
        apply(recovered);
        return;
      }
      id = widget.scope.model.repository.newId();
      cursor = 0;
      await saveHandle();
      widget.scope.check();
      final data = await widget.scope.write(SessionCommand.terminal, {
        'action': commandMode ? 'start' : 'open',
        'id': id,
        if (commandMode) 'command': input.text,
        if (!commandMode) ...{'cols': cols, 'rows': rows},
      });
      if (mounted) {
        apply(data);
        input.clear();
      }
    } catch (e) {
      if (mounted) setState(() => status = businessError(context, e));
    } finally {
      if (mounted) {
        setState(() => busy = false);
        schedule();
      }
    }
  }

  void apply(Json data) {
    if (!mounted) return;
    if (data['reset'] == true) terminal.write('\x1b[2J\x1b[H');
    terminal.write(textValue(data['output']));
    setState(() {
      cursor = (data['cursor'] as num?)?.toInt() ?? cursor;
      running = data['running'] == true;
      status = textValue(
        data['message'] ??
            (running
                ? words(context, '已连接', 'Connected')
                : words(context, '已退出', 'Exited')),
      );
    });
  }

  void schedule() {
    timer?.cancel();
    if (mounted && running && widget.scope.current) {
      timer = Timer(const Duration(milliseconds: 250), poll);
    }
  }

  Future<void> poll() async {
    if (polling || !running || !widget.scope.current) return;
    polling = true;
    final terminalId = id;
    try {
      final data = await widget.scope.read(SessionResource.terminal, {
        'id': terminalId,
        'after': cursor,
        'waitMs': 1000,
        'mode': commandMode ? 'command' : 'pty',
      });
      if (id == terminalId) apply(data);
    } catch (e) {
      if (mounted) setState(() => status = businessError(context, e));
    } finally {
      polling = false;
      schedule();
    }
  }

  void sendInput(String text) {
    if (!running ||
        inputBlocked ||
        commandMode ||
        !widget.scope.current ||
        text.isEmpty) {
      return;
    }
    final inputId = widget.scope.model.repository.newId();
    final terminalId = id;
    inputTail = inputTail.then((_) async {
      if (!mounted ||
          inputBlocked ||
          !widget.scope.current ||
          terminalId != id ||
          !running) {
        return;
      }
      try {
        await widget.scope.write(SessionCommand.terminal, {
          'action': 'input',
          'id': terminalId,
          'inputId': inputId,
          'data': text,
        });
      } catch (e) {
        if (mounted) {
          setState(() {
            inputBlocked = true;
            status =
                '${words(context, '输入结果未确认，请核对终端；不会自动重发', 'Input is unconfirmed; check the terminal. It will not be replayed.')}\n$e';
          });
          try {
            await saveHandle();
          } catch (storageError) {
            if (mounted) setState(() => status = '$status\n$storageError');
          }
        }
      }
    });
  }

  Future<void> resize() async {
    if (!running || commandMode || inputBlocked || !widget.scope.current) {
      return;
    }
    final terminalId = id;
    inputTail = inputTail.then((_) async {
      if (!mounted || !running || !widget.scope.current || terminalId != id) {
        return;
      }
      try {
        await widget.scope.write(SessionCommand.terminal, {
          'action': 'resize',
          'id': terminalId,
          'cols': cols,
          'rows': rows,
        });
      } catch (e) {
        if (mounted) setState(() => status = businessError(context, e));
      }
    });
  }

  Future<void> closeTerminal() async {
    if (id.isEmpty || busy) return;
    if (!await confirmAction(
      context,
      words(context, '关闭终端？', 'Close terminal?'),
      words(
        context,
        '将结束此终端中的程序。',
        'Ends the programs running in this terminal.',
      ),
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      await inputTail;
      await widget.scope.write(SessionCommand.terminal, {
        'action': commandMode ? 'stop' : 'close',
        'id': id,
      });
      await widget.scope.model.saveTerminalHandle(handleKey, null);
      if (mounted) {
        setState(() {
          running = false;
          id = '';
          inputBlocked = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => status = businessError(context, e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> complete() async {
    final before = input.value, terminalId = id;
    if (!before.selection.isCollapsed) return;
    try {
      await inputTail;
      if (!mounted || id != terminalId || input.value != before) return;
      final data = await widget.scope.write(SessionCommand.terminal, {
        'action': 'complete',
        'id': id,
        'text': input.text,
        'selectionStart': input.selection.baseOffset.clamp(
          0,
          input.text.length,
        ),
      });
      if (!mounted || input.value != before || id != terminalId) return;
      final candidates = jsonRows(data['candidates']);
      final chosen = await chooseValue<int>(
        context,
        words(context, '补全', 'Completion'),
        {
          for (var i = 0; i < candidates.length; i++)
            i: textValue(candidates[i]['label']),
        },
      );
      if (chosen != null &&
          mounted &&
          input.value == before &&
          id == terminalId) {
        final row = candidates[chosen];
        final start = (data['replaceStart'] as num?)?.toInt(),
            end = (data['replaceEnd'] as num?)?.toInt();
        if (start == null ||
            end == null ||
            start < 0 ||
            end < start ||
            end > before.text.length ||
            row['insertText'] is! String) {
          throw StateError('Invalid completion range');
        }
        final insert = row['insertText'] as String;
        input.value = TextEditingValue(
          text: before.text.replaceRange(start, end, insert),
          selection: TextSelection.collapsed(offset: start + insert.length),
        );
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  Future<void> reviewInput() async {
    if (!await confirmAction(
      context,
      words(context, '已核对终端结果？', 'Reviewed terminal results?'),
      words(
        context,
        '请先在电脑上核对未确认的终端操作。解除本机阻塞不会重发输入或命令。',
        'Check unconfirmed terminal operations on the computer first. Clearing the local block does not resend input or commands.',
      ),
    )) {
      return;
    }
    try {
      await inputTail;
      await widget.scope.verify();
      final repository = widget.scope.model.repository;
      final pending = await repository.pending(
        widget.scope.session,
        widget.scope.snapshot.accountIdentity,
      );
      for (final operation in pending.where(
        (p) => p.action.startsWith('terminal/'),
      )) {
        await repository.markReviewed(
          widget.scope.session,
          widget.scope.snapshot.accountIdentity,
          operation.id,
        );
      }
      if (!mounted) return;
      setState(() => inputBlocked = false);
      await saveHandle();
      await inspect();
    } catch (e) {
      if (mounted) setState(() => status = businessError(context, e));
    }
  }

  Future<void> forgetTerminal() async {
    if (busy || id.isEmpty) return;
    if (!await confirmAction(
      context,
      words(context, '清除已核对的终端记录？', 'Clear reviewed terminal record?'),
      words(
        context,
        '请先在电脑端确认终端已结束。此操作只清除手机记录，不会停止电脑上的程序，也不会重发命令。',
        'First confirm on the computer that the terminal has ended. This clears the phone record without stopping remote programs or resending commands.',
      ),
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      await inputTail;
      await widget.scope.verify();
      final repository = widget.scope.model.repository;
      for (final operation in await repository.pending(
        widget.scope.session,
        widget.scope.snapshot.accountIdentity,
      )) {
        if (operation.action.startsWith('terminal/')) {
          await repository.markReviewed(
            widget.scope.session,
            widget.scope.snapshot.accountIdentity,
            operation.id,
          );
        }
      }
      timer?.cancel();
      await widget.scope.model.saveTerminalHandle(handleKey, null);
      if (mounted) {
        setState(() {
          id = '';
          cursor = 0;
          running = false;
          inputBlocked = false;
          status = '';
        });
      }
    } catch (e) {
      if (mounted) setState(() => status = businessError(context, e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Wrap(
          spacing: 4,
          children: [
            TextButton(
              onPressed: busy || running ? null : start,
              child: Text(
                words(
                  context,
                  id.isEmpty ? '打开终端' : '核对已有终端',
                  id.isEmpty ? 'Open terminal' : 'Check existing terminal',
                ),
              ),
            ),
            TextButton(
              onPressed: id.isEmpty ? null : closeTerminal,
              child: Text(words(context, '关闭终端', 'Close terminal')),
            ),
            TextButton(
              onPressed: () => terminal.write('\x1b[2J\x1b[H'),
              child: Text(words(context, '清屏', 'Clear')),
            ),
            TextButton(
              onPressed: busy ? null : reviewInput,
              child: Text(
                words(context, '核对未确认操作', 'Review unconfirmed operations'),
              ),
            ),
            if (id.isNotEmpty)
              TextButton(
                onPressed: busy ? null : forgetTerminal,
                child: Text(words(context, '清除已核对记录', 'Clear reviewed record')),
              ),
            if (!commandMode)
              for (final key in {
                'Ctrl+C': '\x03',
                'Tab': '\t',
                'Enter': '\r',
                'Esc': '\x1b',
                '↑': '\x1b[A',
                '↓': '\x1b[B',
              }.entries)
                TextButton(
                  onPressed: running && !inputBlocked
                      ? () => sendInput(key.value)
                      : null,
                  child: Text(key.key),
                ),
          ],
        ),
        Expanded(
          child: TerminalView(
            terminal,
            readOnly: !running || commandMode || inputBlocked || busy,
            keyboardType: TextInputType.multiline,
            textStyle: const TerminalStyle(
              fontFamily: 'PlexMono',
              fontSize: 14,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(status, maxLines: 3, overflow: TextOverflow.ellipsis),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: input,
                  minLines: 1,
                  maxLines: 3,
                  decoration: InputDecoration(
                    hintText: words(
                      context,
                      '命令或回复（换行不会发送）',
                      'Command or reply (newline does not send)',
                    ),
                  ),
                ),
              ),
              if (!commandMode)
                IconButton(
                  onPressed: running && !inputBlocked ? complete : null,
                  icon: const Icon(Icons.auto_fix_high),
                  tooltip: words(context, '补全', 'Complete'),
                ),
              IconButton(
                onPressed: commandMode
                    ? (!running ? start : null)
                    : running && !inputBlocked
                    ? () {
                        sendInput('${input.text}\r');
                        input.clear();
                      }
                    : null,
                icon: const Icon(Icons.send),
                tooltip: words(context, '发送到终端', 'Send to terminal'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
