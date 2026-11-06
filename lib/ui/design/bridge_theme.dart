import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Shared visual contract. Content remains opaque; only chrome uses glass.
ThemeData bridgeTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final blue = dark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF);
  final background = dark ? const Color(0xFF000000) : const Color(0xFFF2F2F7);
  final surface = dark ? const Color(0xFF1C1C1E) : Colors.white;
  final text = dark ? const Color(0xFFF5F5F7) : const Color(0xFF1C1C1E);
  final secondary = dark ? const Color(0xFFAEAEB2) : const Color(0xFF636366);
  final scheme = ColorScheme.fromSeed(seedColor: blue, brightness: brightness)
      .copyWith(
        primary: blue,
        onPrimary: Colors.white,
        primaryContainer: dark
            ? const Color(0xFF102C4B)
            : const Color(0xFFE5F0FF),
        onPrimaryContainer: dark
            ? const Color(0xFFB7D9FF)
            : const Color(0xFF004DA8),
        secondary: blue,
        surface: surface,
        onSurface: text,
        onSurfaceVariant: secondary,
        surfaceContainerLowest: background,
        surfaceContainerLow: dark
            ? const Color(0xFF242426)
            : const Color(0xFFF7F7FA),
        surfaceContainer: dark
            ? const Color(0xFF2C2C2E)
            : const Color(0xFFECECF1),
        surfaceContainerHigh: dark
            ? const Color(0xFF343438)
            : const Color(0xFFE5E5EA),
        outline: secondary,
        outlineVariant: dark
            ? const Color(0xFF38383A)
            : const Color(0xFFDCDCE1),
        error: dark ? const Color(0xFFFF6961) : const Color(0xFFC82A22),
      );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    splashFactory: NoSplash.splashFactory,
    cupertinoOverrideTheme: CupertinoThemeData(
      brightness: brightness,
      primaryColor: blue,
      scaffoldBackgroundColor: background,
      barBackgroundColor: surface.withValues(alpha: .86),
    ),
  );
  final button = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    ),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    textStyle: WidgetStatePropertyAll(
      TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        fontFamily: base.textTheme.bodyMedium?.fontFamily,
      ),
    ),
  );
  return base.copyWith(
    textTheme: base.textTheme
        .copyWith(
          headlineLarge: TextStyle(
            fontSize: 34,
            height: 1.12,
            fontWeight: FontWeight.w700,
            letterSpacing: -.8,
            color: text,
          ),
          headlineMedium: TextStyle(
            fontSize: 28,
            height: 1.18,
            fontWeight: FontWeight.w700,
            letterSpacing: -.5,
            color: text,
          ),
          headlineSmall: TextStyle(
            fontSize: 24,
            height: 1.2,
            fontWeight: FontWeight.w700,
            letterSpacing: -.4,
            color: text,
          ),
          titleLarge: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            letterSpacing: -.3,
            color: text,
          ),
          titleMedium: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: text,
          ),
          bodyLarge: TextStyle(fontSize: 17, height: 1.5, color: text),
          bodyMedium: TextStyle(fontSize: 15, height: 1.45, color: text),
          bodySmall: TextStyle(fontSize: 13, height: 1.4, color: secondary),
        )
        .apply(fontFamily: base.textTheme.bodyMedium?.fontFamily),
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontFamily: base.textTheme.bodyMedium?.fontFamily,
        fontWeight: FontWeight.w600,
        color: text,
      ),
      iconTheme: IconThemeData(color: blue),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: blue, width: 1.5),
      ),
      hintStyle: TextStyle(color: secondary, fontSize: 15),
    ),
    cardTheme: CardThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    filledButtonTheme: FilledButtonThemeData(style: button),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: button.copyWith(
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: button),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.all(12),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: blue,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
      minVerticalPadding: 10,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: .5,
      space: 1,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      titleTextStyle: TextStyle(
        fontSize: 21,
        fontFamily: base.textTheme.bodyMedium?.fontFamily,
        fontWeight: FontWeight.w600,
        color: text,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: blue),
    chipTheme: base.chipTheme.copyWith(
      shape: const StadiumBorder(),
      side: BorderSide.none,
      backgroundColor: scheme.surfaceContainer,
      selectedColor: scheme.primaryContainer,
    ),
  );
}

class BridgeVisualEnvironment extends InheritedWidget {
  const BridgeVisualEnvironment({
    super.key,
    required this.reduceTransparency,
    required super.child,
  });
  final bool reduceTransparency;
  static bool opaque(BuildContext context) =>
      (context
              .dependOnInheritedWidgetOfExactType<BridgeVisualEnvironment>()
              ?.reduceTransparency ??
          false) ||
      MediaQuery.highContrastOf(context) ||
      MediaQuery.accessibleNavigationOf(context);
  @override
  bool updateShouldNotify(BridgeVisualEnvironment oldWidget) =>
      reduceTransparency != oldWidget.reduceTransparency;
}

class BridgeGlass extends StatelessWidget {
  const BridgeGlass({
    super.key,
    required this.child,
    this.radius = 24,
    this.padding = EdgeInsets.zero,
  });
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final opaque = BridgeVisualEnvironment.opaque(context);
    final dark = theme.brightness == Brightness.dark;
    final content = DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(
          alpha: opaque ? 1 : (dark ? .88 : .84),
        ),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: (dark ? Colors.white : Colors.black).withValues(
            alpha: dark ? .12 : .06,
          ),
          width: .7,
        ),
      ),
      child: Padding(padding: padding, child: child),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: opaque
          ? content
          : BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: content,
            ),
    );
  }
}

class BridgeSection extends StatelessWidget {
  const BridgeSection({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    borderRadius: BorderRadius.circular(20),
    child: Padding(padding: padding, child: child),
  );
}

class BridgePageTitle extends StatelessWidget {
  const BridgePageTitle(this.title, {super.key, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineLarge),
              if (subtitle != null) ...[
                const SizedBox(height: 6),
                Text(
                  subtitle!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class BridgeNavigationBar extends StatelessWidget
    implements PreferredSizeWidget {
  const BridgeNavigationBar({super.key, required this.title, this.actions});
  final Widget title;
  final List<Widget>? actions;
  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
  @override
  Widget build(BuildContext context) => AppBar(
    title: title,
    actions: actions,
    backgroundColor: Colors.transparent,
    flexibleSpace: const BridgeGlass(radius: 0, child: SizedBox.expand()),
  );
}
