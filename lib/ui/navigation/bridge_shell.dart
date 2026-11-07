import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../data/bridge_repository.dart';
import '../../l10n/strings.dart';
import '../../viewmodels/bridge_view_model.dart';
import '../../viewmodels/cloud_view_model.dart';
import '../cloud_home.dart';
import '../design/bridge_theme.dart';
import '../pages/chat_page.dart';
import '../pages/connection_page.dart';
import '../pages/session_list_page.dart';
import 'app_navigation.dart';

class BridgeShell extends StatefulWidget {
  const BridgeShell({
    super.key,
    required this.model,
    required this.strings,
    required this.navigation,
    required this.cloud,
    required this.onCloud,
    required this.onComputer,
    required this.settings,
  });
  final BridgeViewModel model;
  final Strings strings;
  final AppNavigationController navigation;
  final CloudViewModel? cloud;
  final VoidCallback onCloud;
  final ValueChanged<Computer> onComputer;
  final Widget settings;
  @override
  State<BridgeShell> createState() => _BridgeShellState();
}

class _BridgeShellState extends State<BridgeShell> {
  final _chatNavigator = GlobalKey<NavigatorState>();
  final _storage = PageStorageBucket();

  void _back() {
    final model = widget.model;
    if (model.busy) return;
    if (widget.navigation.tab == AppTab.chats && model.selected != null) {
      model.backToSessions();
    } else {
      widget.navigation.select(AppTab.computers);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model, s = widget.strings;
    final tab = widget.navigation.tab;
    final wide =
        MediaQuery.sizeOf(context).width >= 840 &&
        MediaQuery.textScalerOf(context).scale(16) < 25.6;
    final detail = tab == AppTab.chats && model.selected != null && !wide;
    return PopScope<Object?>(
      canPop: tab == AppTab.computers && !model.busy,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _back();
      },
      child: Scaffold(
        extendBody: !wide,
        bottomNavigationBar: detail
            ? null
            : BridgeTabBar(navigation: widget.navigation, strings: s),
        body: SafeArea(
          bottom: detail,
          child: PageStorage(
            bucket: _storage,
            child: Stack(
              fit: StackFit.expand,
              children: [
                IndexedStack(
                  index: tab.index,
                  children: [
                    TickerMode(
                      enabled: tab == AppTab.computers,
                      child: CloudHome(
                        model: model,
                        cloud: widget.cloud,
                        strings: s,
                        onCloud: widget.onCloud,
                        onComputer: widget.onComputer,
                      ),
                    ),
                    TickerMode(
                      enabled: tab == AppTab.chats,
                      child: Column(
                        children: [
                          if (model.loading)
                            const LinearProgressIndicator(minHeight: 2),
                          if (model.relayRecovering && !model.loading)
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  const CupertinoActivityIndicator(radius: 8),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      s.notice('Reconnecting to the desktop…'),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          Expanded(
                            child: wide
                                ? _wideChat(context)
                                : _chatStack(context),
                          ),
                        ],
                      ),
                    ),
                    TickerMode(
                      enabled: tab == AppTab.settings,
                      child: widget.settings,
                    ),
                  ],
                ),
                if (model.showError)
                  Positioned(left: 0, right: 0, top: 4, child: _error(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _error(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      key: const Key('connection-error'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .18),
            blurRadius: 16,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(CupertinoIcons.exclamationmark_circle, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.strings.error(widget.model.error!),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          IconButton(
            tooltip: widget.strings.t('Dismiss'),
            onPressed: widget.model.dismissError,
            icon: const Icon(CupertinoIcons.xmark, size: 18),
          ),
        ],
      ),
    ),
  );

  Widget _list(BuildContext context) {
    final model = widget.model, s = widget.strings;
    if (model.computer == null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 120),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                CupertinoIcons.chat_bubble_2,
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 20),
              Text(
                s.t('Your conversations, here.'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 10),
              Text(
                s.t('Choose a computer to continue your work.'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => widget.navigation.select(AppTab.computers),
                child: Text(s.t('Choose computer')),
              ),
            ],
          ),
        ),
      );
    }
    if (!model.authenticated && !model.loading) {
      return ConnectionPage(
        model: model,
        cloud: widget.cloud,
        strings: s,
        onCloud: widget.onCloud,
        onComputer: widget.onComputer,
      );
    }
    return SessionListPage(
      model: model,
      strings: s,
      onInbox: () => _inbox(context),
      onCancelConnection: () async {
        await model.backToComputers();
        if (mounted && model.computer == null) {
          widget.navigation.select(AppTab.computers);
        }
      },
    );
  }

  Widget _listViewport(BuildContext context) => Scaffold(
    primary: false,
    resizeToAvoidBottomInset: false,
    body: Builder(builder: _list),
  );

  Widget _wideChat(BuildContext context) {
    if (!widget.model.authenticated) return _listViewport(context);
    return Row(
      children: [
        SizedBox(width: 340, child: _listViewport(context)),
        const VerticalDivider(width: 1),
        Expanded(
          child: ChatPage(
            model: widget.model,
            strings: widget.strings,
            showBack: false,
          ),
        ),
      ],
    );
  }

  Widget _chatStack(BuildContext context) {
    final session = widget.model.selected;
    final detailKey = ValueKey(('chat-detail', session));
    return Navigator(
      key: _chatNavigator,
      pages: [
        MaterialPage<void>(
          key: const ValueKey('conversation-list'),
          child: _listViewport(context),
        ),
        if (session != null)
          MaterialPage<void>(
            key: detailKey,
            child: PopScope<Object?>(
              canPop: !widget.model.busy,
              child: ChatPage(
                model: widget.model,
                strings: widget.strings,
                showBack: true,
              ),
            ),
          ),
      ],
      onDidRemovePage: (page) {
        if (page.key == detailKey &&
            widget.model.selected == session &&
            session != null) {
          widget.model.backToSessions();
        }
      },
    );
  }

  void _inbox(BuildContext context) {
    final model = widget.model, s = widget.strings;
    model.markInboxRead();
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .65,
          child: Column(
            children: [
              BridgePageTitle(
                s.t('Inbox'),
                subtitle: s.t('No activity gets lost.'),
              ),
              Expanded(
                child: model.inbox.isEmpty
                    ? Center(child: Text(s.t('No new activity')))
                    : ListView.builder(
                        itemCount: model.inbox.length,
                        itemBuilder: (context, index) {
                          final entry = model.inbox[index];
                          return ListTile(
                            leading: const Icon(CupertinoIcons.bell),
                            title: Text(entry.title),
                            subtitle: Text(
                              entry.body,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: entry.session == null
                                ? null
                                : () {
                                    Navigator.pop(context);
                                    model.openInboxEntry(entry);
                                  },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
