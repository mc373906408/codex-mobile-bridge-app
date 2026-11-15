import 'package:flutter/material.dart';

/// Mirrors the web client's model-options list without a second popup menu.
class BridgeOptionList extends StatefulWidget {
  const BridgeOptionList({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.height = 173,
  });
  final Map<String, String> options;
  final String value;
  final ValueChanged<String>? onChanged;
  final double height;
  @override
  State<BridgeOptionList> createState() => _BridgeOptionListState();
}

class _BridgeOptionListState extends State<BridgeOptionList> {
  final scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scroll.hasClients) return;
      final index = widget.options.keys.toList().indexOf(widget.value);
      if (index > 0) {
        scroll.jumpTo(
          (index * 45.0 - widget.height / 2 + 22).clamp(
            0,
            scroll.position.maxScrollExtent,
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      constraints: BoxConstraints(maxHeight: widget.height),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Scrollbar(
        controller: scroll,
        child: ListView.separated(
          key: const Key('model-options'),
          controller: scroll,
          shrinkWrap: true,
          padding: const EdgeInsets.all(5),
          itemCount: widget.options.length,
          separatorBuilder: (_, _) => const SizedBox(height: 3),
          itemBuilder: (context, index) {
            final entry = widget.options.entries.elementAt(index),
                selected = entry.key == widget.value;
            return Semantics(
              selected: selected,
              button: true,
              child: Material(
                color: selected ? colors.primaryContainer : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  onTap: widget.onChanged == null
                      ? null
                      : () => widget.onChanged!(entry.key),
                  borderRadius: BorderRadius.circular(10),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 42),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Tooltip(
                              message: entry.value,
                              child: Text(
                                entry.value,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: selected
                                      ? colors.primary
                                      : colors.onSurface,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (selected)
                            Icon(Icons.check, size: 19, color: colors.primary),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class BridgeChoiceGrid extends StatelessWidget {
  const BridgeChoiceGrid({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });
  final Map<String, String> options;
  final String value;
  final ValueChanged<String>? onChanged;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = options.length;
        var columns = count <= 4
            ? count
            : count <= 6
            ? 3
            : 4;
        if (MediaQuery.textScalerOf(context).scale(12) > 19 ||
            constraints.maxWidth < 240) {
          columns = columns.clamp(1, 2);
        }
        if (columns == 0) return const SizedBox.shrink();
        final width = (constraints.maxWidth - 10 - (columns - 1) * 4) / columns;
        return Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final entry in options.entries)
                SizedBox(
                  width: width,
                  child: Semantics(
                    selected: value == entry.key,
                    button: true,
                    child: Material(
                      color: value == entry.key
                          ? colors.surface
                          : Colors.transparent,
                      elevation: value == entry.key ? 2 : 0,
                      shadowColor: Colors.black12,
                      borderRadius: BorderRadius.circular(9),
                      child: InkWell(
                        onTap: onChanged == null
                            ? null
                            : () => onChanged!(entry.key),
                        borderRadius: BorderRadius.circular(9),
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 38),
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 3,
                            vertical: 9,
                          ),
                          child: Text(
                            entry.value,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: value == entry.key
                                  ? colors.primary
                                  : colors.onSurface,
                              fontWeight: value == entry.key
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

String reasoningLabel(BuildContext context, String value) {
  final chinese = Localizations.localeOf(context).languageCode == 'zh';
  return switch (value) {
    'none' => chinese ? '无' : 'None',
    'minimal' => chinese ? '最低' : 'Minimal',
    'low' => chinese ? '低' : 'Low',
    'medium' => chinese ? '中' : 'Medium',
    'high' => chinese ? '高' : 'High',
    'xhigh' => chinese ? '极高' : 'Extra high',
    'max' => 'Max',
    'ultra' => 'Ultra',
    _ => value,
  };
}
