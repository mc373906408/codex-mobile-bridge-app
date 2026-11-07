import 'package:flutter/material.dart';

import '../data/bridge_repository.dart';
import '../l10n/strings.dart';
import '../viewmodels/bridge_view_model.dart';
import '../viewmodels/cloud_view_model.dart';
import 'cloud_computer_card.dart';
import 'cloud_connection_choices.dart';
import 'cloud_home_sections.dart';
import 'dialogs.dart';

class CloudHome extends StatelessWidget {
  const CloudHome({
    super.key,
    required this.model,
    required this.cloud,
    required this.strings,
    required this.onCloud,
    required this.onComputer,
  });
  final BridgeViewModel model;
  final CloudViewModel? cloud;
  final Strings strings;
  final VoidCallback onCloud;
  final ValueChanged<Computer> onComputer;

  bool get _enabled =>
      model.initialized &&
      !model.busy &&
      model.foreground &&
      cloud?.busy != true;

  List<Computer> _visibleComputers() {
    final computers = {
      for (final computer in model.computers)
        if (computer.connectionType != ConnectionType.relay)
          computer.id: computer,
    };
    final current = cloud;
    if (current == null || !current.signedIn) return computers.values.toList();
    // Offline cloud identities stay stored and reappear when online again.
    for (final state in current.devices) {
      final online =
          current.discoveryError == null && state.device.gateway.online;
      if ((online || current.p2pConnected(state.computer)) &&
          current.matches(state.computer)) {
        computers[state.computer.id] = state.computer;
      }
    }
    return computers.values.toList();
  }

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor),
    child: RefreshIndicator(
      onRefresh: () => cloud?.refresh() ?? Future<void>.value(),
      child: SingleChildScrollView(
        key: const Key('cloud-home-scroll'),
        physics: const AlwaysScrollableScrollPhysics(),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _heading(context),
                  const SizedBox(height: 18),
                  CloudConnectionChoices(
                    strings: strings,
                    cloudEnabled: cloud?.canManage == true,
                    directEnabled: _enabled,
                    signedIn: cloud?.signedIn == true,
                    onCloud: onCloud,
                    onDirect: () => addComputerDialog(
                      context,
                      model,
                      strings,
                      cloud: cloud,
                      onCloud: onCloud,
                    ),
                  ),
                  const SizedBox(height: 24),
                  ..._computerList(context),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _heading(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        strings.t('Computers'),
        style: Theme.of(context).textTheme.headlineLarge,
      ),
      const SizedBox(height: 6),
      Text(
        strings.t('Connect your computer'),
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ],
  );

  List<Widget> _computerList(BuildContext context) {
    final computers = _visibleComputers();
    return [
      CloudHomeSectionTitle(
        key: const Key('saved-computers-section'),
        title: strings.t('Saved computers'),
        count: computers.length,
      ),
      const SizedBox(height: 8),
      if (computers.isEmpty) _emptyConnections(),
      if (cloud?.discoveryError case final error?)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            strings.error(error),
            key: const Key('cloud-discovery-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      for (final computer in computers)
        CloudComputerCard(
          key: ValueKey('computer-card-${computer.id}'),
          computer: computer,
          model: model,
          cloud: cloud,
          strings: strings,
          enabled: _enabled,
          onComputer: onComputer,
        ),
      if (computers.any(
        (computer) => computer.connectionType == ConnectionType.direct,
      ))
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            strings.t('Swipe left to remove a direct connection'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
    ];
  }

  Widget _emptyConnections() => CloudHomeEmptyConnections(
    icon: Icons.computer_rounded,
    title: strings.t(
      cloud?.signedIn == true
          ? 'No online cloud computers'
          : 'No computers yet',
    ),
    description: strings.t(
      cloud?.signedIn == true
          ? 'Offline cloud computers stay saved and reappear automatically when they reconnect.'
          : 'Sign in to discover your cloud computers, or add a direct connection.',
    ),
  );
}
