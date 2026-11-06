import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../design/bridge_theme.dart';

enum AppTab { computers, chats, settings }

/// Presentation state only. Selecting a tab must never mutate a connection.
class AppNavigationController extends ChangeNotifier {
  AppNavigationController({AppTab initial = AppTab.computers}) : _tab = initial;
  AppTab _tab;
  AppTab get tab => _tab;
  void select(AppTab value) {
    if (value == _tab) return;
    _tab = value;
    notifyListeners();
  }
}

class BridgeTabBar extends StatelessWidget {
  const BridgeTabBar({
    super.key,
    required this.navigation,
    required this.strings,
  });
  final AppNavigationController navigation;
  final Strings strings;
  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    minimum: const EdgeInsets.fromLTRB(20, 8, 20, 10),
    child: Center(
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: BridgeGlass(
          radius: 32,
          padding: const EdgeInsets.all(5),
          child: Row(
            children: [
              for (final entry in [
                (AppTab.computers, CupertinoIcons.desktopcomputer, 'Computers'),
                (AppTab.chats, CupertinoIcons.chat_bubble_2, 'Chats'),
                (AppTab.settings, CupertinoIcons.gear, 'Settings'),
              ])
                Expanded(
                  child: _Tab(
                    tab: entry.$1,
                    icon: entry.$2,
                    label: strings.t(entry.$3),
                    selected: navigation.tab == entry.$1,
                    onTap: () {
                      FocusManager.instance.primaryFocus?.unfocus();
                      navigation.select(entry.$1);
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.tab,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final AppTab tab;
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: Semantics(
        selected: selected,
        button: true,
        label: label,
        child: GestureDetector(
          key: ValueKey('tab-${tab.name}'),
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: ExcludeSemantics(
            child: AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              constraints: const BoxConstraints(minHeight: 56),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
              decoration: BoxDecoration(
                color: selected
                    ? colors.primary.withValues(alpha: .1)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(27),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 24,
                    color: selected ? colors.primary : colors.onSurfaceVariant,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.15,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
