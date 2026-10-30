// @dart = 3.13

import 'dart:convert';
import 'dart:io';

import 'package:typed_config/typed_config.dart';

/// ---------------------------------------------------------------------------
/// Enums & Custom Object
/// ---------------------------------------------------------------------------

// NOTE: This example uses Dart 3.13+ Primary Constructors syntax.
// If your project uses Dart 3.2 - 3.12, see the README for standard constructor patterns.

enum ThemeMode { system, light, dark }

final class const WindowSize(final int width, final int height) {
  factory fromJson(dynamic json) {
    if (json is Map) {
      final width = (json['width'] as num?)?.toInt() ?? 1280;
      final height = (json['height'] as num?)?.toInt() ?? 720;
      return WindowSize(width, height);
    }
    return const WindowSize(1280, 720);
  }

  Map<String, dynamic> toJson() => {'width': width, 'height': height};

  @override
  String toString() => '${width}x$height';
}

/// ---------------------------------------------------------------------------
/// Defining config & Sub-group (using Dart 3.13+ Primary Constructors)
/// ---------------------------------------------------------------------------

/// Sub-group for UI config: 'ui.*'
final class UiConfig(super.builder) extends TypedConfig {
  // Enum config
  final themeMode = builder.defineEnum('themeMode', ThemeMode.system, values: ThemeMode.values);
  final compactMode = builder.define('compactMode', false);
  final fontScale = builder.define('fontScale', 1.0);
}

/// Main application configuration.
final class AppConfig(super.builder) extends TypedConfig {
  // Standard built-in type configs (String, bool, int, double)
  final language = builder.define('language', 'en');
  final autoCheckUpdates = builder.define('autoCheckUpdates', true);

  // Custom serializable object config
  final windowSize = builder.define(
    'windowSize',
    const WindowSize(1280, 720),
    fromJson: WindowSize.fromJson,
    toJson: (size) => size.toJson(),
  );

  // List of built-in types
  final recentFiles = builder.defineList<String>('recentFiles', const []);

  // Nested config group
  final ui = builder.group('ui', UiConfig.new);
}

/// ---------------------------------------------------------------------------
/// Usage Example
/// ---------------------------------------------------------------------------

Future<void> main() async {
  print('=== typed_config Example ===\n');

  // Use a temporary file for this demo run
  final tempDir = await Directory.systemTemp.createTemp('typed_config_demo_');
  final configFile = File('${tempDir.path}/app_config.json');

  try {
    // -------------------------------------------------------------------------
    // Scenario: An existing user has a legacy Version 1 config file on disk.
    // In v1, 'theme' was at the root level, but v2 organizes it under 'ui.themeMode'.
    // -------------------------------------------------------------------------
    await configFile.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'language': 'id',
        'theme': 'dark', // Old location in v1!
        'autoCheckUpdates': false,
      }),
    );
    print('1. Initialized simulated v1 configuration file on disk:');
    print('   ${await configFile.readAsString()}\n');

    // -------------------------------------------------------------------------
    // Initialize with Schema Migration to Version 2
    // -------------------------------------------------------------------------
    print('2. Initializing AppConfig with schemaVersion: 2 & migrations...');
    final appConfig = await TypedConfig.initialize(
      configFile: configFile,
      create: AppConfig.new,
      schemaVersion: 2,
      migrations: {
        2: (migrator) {
          // Move legacy flat 'theme' to nested 'ui.themeMode'
          migrator.rename(['theme'], ['ui', 'themeMode']);
        },
      },
      onLog: (message) => print('   $message'),
    );

    // -------------------------------------------------------------------------
    // Reading Typed Values & Checking isDefault
    // -------------------------------------------------------------------------
    print('\n3. Reading strongly-typed values:');
    print(
      '   - Language: "${appConfig.language.value}" (isDefault: ${appConfig.language.isDefault})',
    );
    print(
      '   - Auto Check Updates: ${appConfig.autoCheckUpdates.value} (isDefault: ${appConfig.autoCheckUpdates.isDefault})',
    );
    print(
      '   - Theme Mode: ${appConfig.ui.themeMode.value} (migrated from v1, isDefault: ${appConfig.ui.themeMode.isDefault})',
    );
    print('   - Compact Mode: ${appConfig.ui.compactMode.value}');
    print('   - Font Scale: ${appConfig.ui.fontScale.value}');
    print(
      '   - Window Size: ${appConfig.windowSize.value} (default, isDefault: ${appConfig.windowSize.isDefault})',
    );

    // -------------------------------------------------------------------------
    // Subscribing to Reactive Changes
    // -------------------------------------------------------------------------
    print('\n4. Listening to reactive change streams...');
    final themeSubscription = appConfig.ui.themeMode.changes.listen((newTheme) {
      print('   -> [Stream Event] UI theme mode updated to: $newTheme');
    });

    final fontSubscription = appConfig.ui.fontScale.changes.listen((newScale) {
      print('   -> [Stream Event] UI font scale updated to: $newScale');
    });

    // -------------------------------------------------------------------------
    // Updating Settings
    // -------------------------------------------------------------------------
    print('\n5. Updating settings...');
    appConfig.ui.themeMode.value = ThemeMode.light;
    appConfig.ui.compactMode.value = true;
    appConfig.ui.fontScale.value = 1.25;
    appConfig.windowSize.value = const WindowSize(1920, 1080);
    appConfig.recentFiles.value = ['/docs/report.pdf', '/docs/notes.txt'];

    // Give streams a moment to deliver events
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // -------------------------------------------------------------------------
    // Resetting an Individual Entry
    // -------------------------------------------------------------------------
    print('\n6. Resetting compact mode to default...');
    print(
      '   Compact mode before reset: ${appConfig.ui.compactMode.value} (isDefault: ${appConfig.ui.compactMode.isDefault})',
    );
    appConfig.ui.compactMode.reset();
    print(
      '   Compact mode after reset: ${appConfig.ui.compactMode.value} (isDefault: ${appConfig.ui.compactMode.isDefault})',
    );

    // -------------------------------------------------------------------------
    // Persisting Changes to Disk
    // -------------------------------------------------------------------------
    print('\n7. Forcing flush to disk...');
    await appConfig.flush();

    print('   Updated file content on disk:');
    final encoder = JsonEncoder.withIndent('  ');
    final diskContent = jsonDecode(await configFile.readAsString());
    print(encoder.convert(diskContent));

    // -------------------------------------------------------------------------
    // In-Memory Mode (For Tests / Headless)
    // -------------------------------------------------------------------------
    print('\n8. In-Memory Mode (Testing without touching disk):');
    final testConfig = TypedConfig.inMemory(
      create: AppConfig.new,
      initialData: {
        'language': 'fr',
        'ui': {'compactMode': true},
      },
    );
    print('   - In-memory Language: ${testConfig.language.value}');
    print('   - In-memory Compact Mode: ${testConfig.ui.compactMode.value}');
    print('   - In-memory Theme Mode: ${testConfig.ui.themeMode.value} (default)');
    testConfig.dispose();

    // -------------------------------------------------------------------------
    // Cleanup & Disposal
    // -------------------------------------------------------------------------
    print('\n9. Disposing config and cleaning up resources...');
    await themeSubscription.cancel();
    await fontSubscription.cancel();
    appConfig.dispose();

    print('\n=== All typed_config features demonstrated successfully! ===');
  } finally {
    // Clean up temporary directory
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  }
}
