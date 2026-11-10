import '../data/bridge_repository.dart';

String providerName(Provider value) => switch (value) {
  Provider.codex => 'Codex',
  Provider.claude => 'Claude',
  Provider.deepseek => 'DeepSeek',
  Provider.zcode => 'ZCode',
};
