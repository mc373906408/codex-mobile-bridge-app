import 'dart:convert';

import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import '../../l10n/user_messages.dart';
import '../../viewmodels/bridge_view_model.dart';
export '../../viewmodels/bridge_view_model.dart';

typedef Json = Map<String, dynamic>;
Json jsonObject(Object? value) {
  if (value is String) value = jsonDecode(value);
  return value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
}

List<Json> jsonRows(Object? value) =>
    value is List ? value.whereType<Map>().map(jsonObject).toList() : [];
String textValue(Object? value) => value == null ? '' : value.toString();
String words(BuildContext context, String zh, String en) =>
    Localizations.localeOf(context).languageCode == 'zh' ? zh : en;
String businessError(BuildContext context, Object? error) => localizedError(
  error ?? StateError('The operation result could not be confirmed'),
  chinese: Localizations.localeOf(context).languageCode == 'zh',
);

/// A page retains the identity that authorized opening it. Reads and writes
/// from an old connection/account are discarded, including after backgrounding.
class SessionBusiness {
  SessionBusiness(this.model, this.snapshot)
    : connection = model.connectionGeneration;
  final BridgeViewModel model;
  final int connection;
  SessionSnapshot snapshot;
  bool disposed = false;
  bool busy = false;
  SessionRef get session => snapshot.session;
  Json get metadata => jsonObject(snapshot.metadata);
  Json get state =>
      metadata['session'] is Map ? jsonObject(metadata['session']) : metadata;
  Json get capabilities => metadata['capabilities'] is Map
      ? jsonObject(metadata['capabilities'])
      : jsonObject(state['capabilities']);
  String get wireAccount => textValue(
    metadata['draftAccountIdentity'] ?? state['draftAccountIdentity'],
  );
  bool get current =>
      !disposed &&
      model.foreground &&
      model.authenticated &&
      model.connectionGeneration == connection &&
      model.computer?.id == session.computerId;
  void check() {
    if (!current) throw StateError('Connection changed; reopen this page');
  }

  Future<SessionSnapshot> _authority() async {
    check();
    final value = await model.repository.snapshot(session);
    check();
    if (value.accountIdentity.isEmpty ||
        value.accountIdentity != snapshot.accountIdentity) {
      throw StateError('Account changed; reopen this page');
    }
    return value;
  }

  Future<void> verify() async {
    await _authority();
  }

  Future<void> refresh() async {
    snapshot = await _authority();
  }

  Future<Json> read(
    SessionResource resource, [
    Json parameters = const {},
  ]) async {
    await _authority();
    final data = await model.repository.sessionResource(
      session,
      resource,
      parameters,
    );
    await _authority();
    return jsonObject(data);
  }

  Future<Json> write(SessionCommand command, Json parameters) async {
    check();
    if (busy) throw StateError('An operation is still in progress');
    busy = true;
    try {
      final result = await model.repository.sessionCommand(
        snapshot,
        model.repository.newId(),
        command,
        parameters,
      );
      check();
      if (result.outcome.kind != OutcomeKind.accepted) {
        throw StateError(result.outcome.message);
      }
      if (command != SessionCommand.delete) snapshot = await _authority();
      return jsonObject(result.data);
    } finally {
      busy = false;
    }
  }

  void dispose() {
    disposed = true;
  }
}

class GatewayBusiness {
  GatewayBusiness(this.model, {Provider? provider, String? entry})
    : computer = model.computer!,
      connection = model.connectionGeneration,
      provider = provider ?? model.provider,
      entry = entry ?? model.entry;
  final BridgeViewModel model;
  final Computer computer;
  final int connection;
  final Provider provider;
  final String entry;
  String identity = '';
  final identities = <bool, String>{};
  bool accountResource(GatewayResource resource) => const {
    GatewayResource.accounts,
    GatewayResource.account,
    GatewayResource.projects,
    GatewayResource.creationModels,
    GatewayResource.wslAccounts,
  }.contains(resource);
  bool accountCommand(GatewayCommand command) => const {
    GatewayCommand.accountDetails,
    GatewayCommand.switchAccount,
    GatewayCommand.browseProjects,
    GatewayCommand.registerProject,
    GatewayCommand.trustProject,
    GatewayCommand.accountReminders,
    GatewayCommand.resetDynamic,
    GatewayCommand.desktopUpdate,
    GatewayCommand.initializeCodex,
    GatewayCommand.sshRetry,
    GatewayCommand.wslAccounts,
  }.contains(command);
  bool disposed = false, busy = false;
  void check() {
    if (disposed ||
        !model.authenticated ||
        !model.foreground ||
        model.connectionGeneration != connection ||
        model.computer?.id != computer.id) {
      throw StateError('Connection changed; reopen this page');
    }
  }

  Future<Json> read(
    GatewayResource resource, [
    Json parameters = const {},
  ]) async {
    check();
    final value = await model.repository.gatewayResource(
      computer,
      provider,
      entry,
      resource,
      parameters,
    );
    check();
    final bound = accountResource(resource);
    if (identities[bound] != null && identities[bound] != value.identity) {
      throw StateError('Account changed; reopen this page');
    }
    identity = value.identity;
    identities[bound] = identity;
    return jsonObject(value.data);
  }

  Future<Json> write(GatewayCommand command, Json parameters) async {
    check();
    if (busy) throw StateError('An operation is still in progress');
    final bound = accountCommand(command);
    if (identities[bound] == null) {
      await read(
        !bound
            ? GatewayResource.clients
            : command == GatewayCommand.wslAccounts
            ? GatewayResource.wslAccounts
            : GatewayResource.accounts,
      );
    }
    busy = true;
    try {
      final value = await model.repository.gatewayCommand(
        computer,
        provider,
        entry,
        identities[bound]!,
        model.repository.newId(),
        command,
        parameters,
      );
      check();
      if (value.outcome.kind != OutcomeKind.accepted) {
        throw StateError(value.outcome.message);
      }
      if (command == GatewayCommand.switchAccount ||
          command == GatewayCommand.wslAccounts) {
        identities.remove(true);
      }
      return jsonObject(value.data);
    } finally {
      busy = false;
    }
  }

  void dispose() {
    disposed = true;
  }
}

Future<void> reviewGatewayOperations(
  BuildContext context,
  GatewayBusiness scope,
) async {
  try {
    final data = await scope.read(GatewayResource.pendingOperations);
    final session = SessionRef(
      computerId: scope.computer.id,
      provider: scope.provider,
      entry: scope.entry,
      environment: 'local',
      id: 'management',
    );
    final operations = jsonRows(data['operations']);
    scope.check();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(words(context, '待核对操作', 'Pending verification')),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  words(
                    context,
                    '请先在电脑端核对结果。标记已核对不会重发请求，也不表示操作成功。',
                    'Check the result on the computer first. Marking it reviewed does not resend it or claim success.',
                  ),
                ),
                if (operations.isEmpty)
                  Text(
                    words(
                      context,
                      '当前作用域没有待核对操作',
                      'No pending operations in the current scope',
                    ),
                  ),
                for (final pending in operations)
                  ListTile(
                    title: Text(textValue(pending['action'])),
                    subtitle: Text('${pending['id']}\n${pending['message']}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.check_circle_outline),
                      tooltip: words(
                        context,
                        '我已在电脑核对',
                        'I checked on the computer',
                      ),
                      onPressed: () async {
                        try {
                          scope.check();
                          await scope.model.repository.markReviewed(
                            session,
                            textValue(pending['identity']),
                            textValue(pending['id']),
                          );
                          if (dialog.mounted) Navigator.pop(dialog);
                        } catch (error) {
                          if (dialog.mounted) showFailure(dialog, error);
                        }
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(words(context, '关闭', 'Close')),
          ),
        ],
      ),
    );
  } catch (error) {
    if (context.mounted) showFailure(context, error);
  }
}

Future<bool> confirmAction(
  BuildContext context,
  String title,
  String explanation, {
  String? confirm,
  bool danger = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: SelectableText(explanation)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(words(context, '取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            style: danger
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                  )
                : null,
            child: Text(confirm ?? words(context, '确认', 'Confirm')),
          ),
        ],
      ),
    ) ??
    false;

Future<String?> promptText(
  BuildContext context,
  String title, {
  String initial = '',
  String? description,
  bool multiline = false,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (description != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(description),
              ),
            TextField(
              controller: controller,
              autofocus: true,
              minLines: multiline ? 3 : 1,
              maxLines: multiline ? 8 : 1,
              decoration: InputDecoration(labelText: title),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: Text(words(context, '取消', 'Cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialog, controller.text),
          child: Text(words(context, '确认', 'Confirm')),
        ),
      ],
    ),
  );
  // Dialog animations can retain the field briefly after the route completes.
  Future<void>.delayed(const Duration(milliseconds: 500), controller.dispose);
  return result;
}

Future<T?> chooseValue<T>(
  BuildContext context,
  String title,
  Map<T, String> choices,
) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (dialog) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: .5,
    builder: (_, scroll) => ListView(
      controller: scroll,
      children: [
        ListTile(
          title: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        for (final entry in choices.entries)
          ListTile(
            title: Text(entry.value),
            onTap: () => Navigator.pop(dialog, entry.key),
          ),
      ],
    ),
  ),
);

void showFailure(BuildContext context, Object error) {
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(businessError(context, error))));
  }
}

class BusinessLoading extends StatelessWidget {
  const BusinessLoading({super.key, this.error, required this.retry});
  final Object? error;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: error == null
          ? const CircularProgressIndicator()
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText(businessError(context, error)),
                  TextButton(
                    onPressed: retry,
                    child: Text(words(context, '重新读取', 'Reload')),
                  ),
                ],
              ),
            ),
    ),
  );
}

class DetailTextPage extends StatelessWidget {
  const DetailTextPage({super.key, required this.title, required this.text});
  final String title, text;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: SelectableText(
        text,
        style: const TextStyle(fontFamily: 'PlexMono', height: 1.5),
      ),
    ),
  );
}
