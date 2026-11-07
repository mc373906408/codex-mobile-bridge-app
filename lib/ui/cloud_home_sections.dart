import 'package:flutter/material.dart';

class CloudHomeSectionTitle extends StatelessWidget {
  const CloudHomeSectionTitle({
    super.key,
    required this.title,
    required this.count,
  });
  final String title;
  final int count;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      ),
      const SizedBox(width: 8),
      Text(
        '$count',
        style: TextStyle(
          fontFamily: 'PlexMono',
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
}

class CloudHomeEmptyConnections extends StatelessWidget {
  const CloudHomeEmptyConnections({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
  });
  final IconData icon;
  final String title, description;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary, size: 22),
        const SizedBox(height: 10),
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Text(description, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}
