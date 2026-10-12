import 'dart:io';

import 'package:typed_config/typed_config.dart';

enum ThemeMode { system, light, dark }

// Main application config
class AppConfig(ConfigBuilder builder) extends Config {
  final language = builder.define('language', 'en');
  final autoCheckUpdates = builder.define('autoCheckUpdates', true);

  // If you want to organize your config into group
  final ui = UiSettings(builder.withPrefix('ui'));
}

// Grouped config
class UiSettings(ConfigBuilder builder) {
  final themeMode = builder.defineEnum('themeMode', ThemeMode.system, values: ThemeMode.values);
  final compactMode = builder.define('compactMode', false);
  final fontScale = builder.define('fontScale', 1.0);
}

void main() async {
  final tempDir = await Directory.systemTemp.createTemp('typed_config_example_');
  final configFile = File('${tempDir.path}/config.json');

  // Initialize once via constructor tear-off (AppConfig.new)
  final config = await Config.initialize(AppConfig.new, configFile);

  // Synchronous reads
  print('Language: ${config.language.value}'); // en
  print('Theme: ${config.ui.themeMode.value}'); // ThemeMode.system
  print('Font scale: ${config.ui.fontScale.value}'); // 1.0

  // Update values (immediate in memory, debounced in disk save)
  config.language.value = 'id';
  config.ui.themeMode.value = ThemeMode.dark;
  config.ui.fontScale.value = 1.2;

  print('\nUpdated language: ${config.language.value}'); // id
  print('Updated theme: ${config.ui.themeMode.value}'); // ThemeMode.dark

  // Check if customized
  print('Is theme customized? ${config.ui.themeMode.isModified}'); // true

  // Reset single setting back to default
  config.ui.themeMode.reset();
  print('Reset theme: ${config.ui.themeMode.value}'); // ThemeMode.system
  print('Is theme customized now? ${config.ui.themeMode.isModified}'); // false

  // Reset all settings back to defaults
  await config.resetAll();

  // Inspect nested JSON output on disk
  await config.flush();
  print('\nOn-disk JSON:\n${await configFile.readAsString()}');

  config.dispose();
  await tempDir.delete(recursive: true);
}
