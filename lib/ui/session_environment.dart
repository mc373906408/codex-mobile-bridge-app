String sessionEnvironmentName(
  String environment, {
  required String computerName,
  String label = '',
}) {
  if (environment == 'local') return computerName;
  final name = label.trim().isEmpty ? environment : label;
  for (final prefix in const [
    'remote-ssh-discovered:',
    'ssh:',
    'remote-ssh:',
  ]) {
    if (environment.startsWith(prefix)) {
      return 'SSH · ${label.trim().isEmpty ? environment.substring(prefix.length) : name}';
    }
  }
  return name;
}
