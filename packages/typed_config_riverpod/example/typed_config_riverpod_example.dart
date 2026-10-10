import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:typed_config_riverpod/typed_config_riverpod.dart';

enum ThemeMode { system, light, dark }

// Grouping configs inside an abstract final class is optional, but recommended
// for clean namespacing and IDE autocomplete (e.g. typing `AppConfig.` reveals all settings).
abstract final class AppConfig {
  static final volumeProvider = configEntryProvider<double>(key: 'volume', defaultValue: 0.8);

  static final themeModeProvider = configEntryProvider<ThemeMode>(
    key: 'themeMode',
    defaultValue: ThemeMode.system,
    fromJson: (j) => ThemeMode.values.byName(j as String),
    toJson: (m) => m.name,
  );
}

void main() async {
  final tempDir = await Directory.systemTemp.createTemp('riverpod_example_');
  final configFile = File('${tempDir.path}/config.json');

  // Initialize core Config
  final config = await Config.load(configFile);

  // Set up Riverpod container with configProvider override
  final container = ProviderContainer(overrides: [configProvider.overrideWithValue(config)]);

  // Synchronous read
  print('Initial volume: ${container.read(AppConfig.volumeProvider)}'); // 0.8

  // Update via Notifier (immediate in memory, debounced in disk save)
  container.read(AppConfig.volumeProvider.notifier).set(0.95);
  print('Updated volume: ${container.read(AppConfig.volumeProvider)}'); // 0.95

  // Reset via Notifier (back to default value)
  container.read(AppConfig.volumeProvider.notifier).reset();
  print('Reset volume: ${container.read(AppConfig.volumeProvider)}'); // 0.8

  container.dispose();
  config.dispose();
  await tempDir.delete(recursive: true);
}
