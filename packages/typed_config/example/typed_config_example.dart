import 'dart:io';

import 'package:typed_config/typed_config.dart';

enum ThemeMode { system, light, dark }

// Grouping configs inside an abstract final class is optional, but recommended
// for clean namespacing and IDE autocomplete (e.g. typing `AppConfig.` reveals all settings).
abstract final class AppConfig {
  static const volume = ConfigEntry<double>(key: 'volume', defaultValue: 0.8);
  static final themeMode = ConfigEntry<ThemeMode>(
    key: 'themeMode',
    defaultValue: ThemeMode.system,
    fromJson: (j) => ThemeMode.values.byName(j as String),
    toJson: (m) => m.name,
  );
}

void main() async {
  final tempDir = await Directory.systemTemp.createTemp(
    'typed_config_example_',
  );
  final configFile = File('${tempDir.path}/config.json');

  // Initialize once
  final config = await Config.load(configFile);

  // Synchronous read
  print('Initial volume: ${config.get(AppConfig.volume)}'); // 0.8
  print(
    'Initial theme: ${config.get(AppConfig.themeMode)}',
  ); // ThemeMode.system

  // Update value (immediate in memory, debounced in disk save)
  config.set(AppConfig.volume, 0.95);
  config.set(AppConfig.themeMode, ThemeMode.dark);

  print('Updated volume: ${config.get(AppConfig.volume)}'); // 0.95

  // Reset single setting back to default
  config.reset(AppConfig.volume);
  print('Reset volume: ${config.get(AppConfig.volume)}'); // 0.8

  // Reset all settings back to defaults
  await config.resetAll();

  // Inspect nested JSON output on disk
  await config.flush();
  print('\nOn-disk JSON:\n${await configFile.readAsString()}');

  config.dispose();
  await tempDir.delete(recursive: true);
}
