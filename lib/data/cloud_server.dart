const officialCloudOrigin = 'https://bridge.waken.cloudns.be:8787';

String cloudOriginInput(String input) {
  final value = input.trim();
  final uri = Uri.tryParse(value);
  // Only the root slash is input convenience; the native origin check stays strict.
  if (uri != null &&
      uri.path == '/' &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      value.endsWith('/')) {
    return value.substring(0, value.length - 1);
  }
  return value;
}
