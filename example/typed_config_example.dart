// @dart=3.13
import 'dart:io';

import 'package:typed_config/typed_config.dart';

// ================================================================================================
// Enums and Custom Models
// ================================================================================================

enum ThemeMode { system, light, dark }

/// Custom configuration model with JSON serialization.
class WindowSize {
  final int width;
  final int height;

  const WindowSize(this.width, this.height);

  Map<String, dynamic> toJson() => {'width': width, 'height': height};

  factory WindowSize.fromJson(dynamic json) {
    if (json is Map) {
      return WindowSize(
        (json['width'] as num?)?.toInt() ?? 1280,
        (json['height'] as num?)?.toInt() ?? 720,
      );
    }
    return const WindowSize(1280, 720);
  }

  @override
  String toString() => '${width}x$height';
}

// ================================================================================================
// Domain-Driven Configuration Schema
// ================================================================================================

/// Sub-group for UI settings.
///
/// Primary constructors (dart 3.13) provide the cleanest syntax with automatic type inference.
class UiSettings(ConfigBuilder builder) {
  final themeMode = builder.defineEnum('themeMode', ThemeMode.system, values: ThemeMode.values);
  final fontScale = builder.define('fontScale', 1.0);
  final windowSize = builder.define(
    'windowSize',
    const WindowSize(1280, 720),
    fromJson: WindowSize.fromJson,
    toJson: (w) => w.toJson(),
  );
}

/// Sub-group for Audio settings.
///
/// But for version below 3.13, standard constructor initializer lists are also fully supported.
class AudioSettings {
  final ConfigEntry<double> volume;
  final ConfigEntry<bool> muted;

  AudioSettings(ConfigBuilder builder)
    : volume = builder.define('volume', 0.8),
      muted = builder.define('muted', false);
}

/// Main Application Configuration.
class AppConfig(ConfigBuilder builder) extends Config {
  final language = builder.define('language', 'en');
  final tags = builder.defineList('tags', ['general', 'updates']);
  final audio = AudioSettings(builder.withPrefix('audio'));
  final ui = UiSettings(builder.withPrefix('ui'));
}

// ================================================================================================
// Execution & Lifecycle Showcase
// ================================================================================================

void main() async {
  final tempDir = await Directory.systemTemp.createTemp('typed_config_example_');
  final configFile = File('${tempDir.path}/config.json');

  print('=== typed_config Complete Usage Showcase ===\n');

  try {
    // ============================================================================================
    // Initializing from Disk with Migrations
    // ============================================================================================
    print('Initializing configuration from disk...');

    // Config.initialize loads the file asynchronously once at app bootstrap.
    // All subsequent reads anywhere in the app are 100% synchronous in memory.
    final config = await Config.initialize(
      AppConfig.new,
      configFile,
      schemaVersion: 2,
      migrations: {
        2: (m) {
          // Drift-style transactional schema migrations:
          m.rename('old_language', 'language');
          m.transform<num>('audio.volume', (v) => (v / 100.0).clamp(0.0, 1.0));
          m.removePrefix('legacy_telemetry.');
        },
      },
      onLog: (msg) => print('  [Config Log] $msg'),
    );

    // ============================================================================================
    // Synchronous In-Memory Reads
    // ============================================================================================
    print('\nSynchronous in-memory reads (zero async latency):');
    print('  Language:    ${config.language.value}');
    print('  Tags:        ${config.tags.value}');
    print('  Audio Vol:   ${config.audio.volume.value}');
    print('  Theme Mode:  ${config.ui.themeMode.value}');
    print('  Window Size: ${config.ui.windowSize.value}');

    // ============================================================================================
    // Fine-Grained Reactive Change Subscriptions
    // ============================================================================================
    print('\nListening to entry-specific change stream:');
    final subscription = config.audio.volume.changes.listen((newVolume) {
      print('  -> [Stream Event] Audio volume changed to: $newVolume');
    });

    // ============================================================================================
    // Direct In-Memory Writes & Debounced Persistence
    // ============================================================================================
    print('\nChange settings:');
    // Updates RAM instantly, notifies listeners immediately, debounces disk save
    config.language.value = 'id';
    config.audio.volume.value = 0.5;
    config.ui.themeMode.value = ThemeMode.dark;
    config.ui.windowSize.value = const WindowSize(1920, 1080);
    config.tags.value = ['featured', 'release'];

    print('  Updated Language:    ${config.language.value}');
    print('  Updated Theme Mode:  ${config.ui.themeMode.value}');
    print('  Updated Window Size: ${config.ui.windowSize.value}');

    // Allow event loop to process stream notification
    await Future<void>.delayed(Duration.zero);

    // ============================================================================================
    // Checking Overrides & Reverting (Reset)
    // ============================================================================================
    print('\nChecking modification status & resetting:');
    print('  Is volume customized? ${config.audio.volume.isModified}'); // true

    // Revert a single entry back to its default value
    config.audio.volume.reset();
    await Future<void>.delayed(Duration.zero);
    print('  Volume after reset(): ${config.audio.volume.value}'); // 0.8
    print('  Is volume customized? ${config.audio.volume.isModified}'); // false

    // Flush dirty state to disk immediately without waiting for debounce timer
    await config.flush();

    // ============================================================================================
    // Inspecting On-Disk Nested JSON
    // ============================================================================================
    print('\nFormatted indented JSON persisted on disk:');
    final diskJson = await configFile.readAsString();
    print(diskJson);

    // Clean up streams and active timers
    await subscription.cancel();
    config.dispose();

    // ============================================================================================
    // In-Memory Mode for Unit Testing
    // ============================================================================================
    print('In-Memory testing mode (zero file I/O):');
    final testConfig = Config.inMemory(AppConfig.new, {'language': 'ja', 'ui.themeMode': 'light'});
    print('  In-memory test language: ${testConfig.language.value}'); // ja
    print('  In-memory test theme:    ${testConfig.ui.themeMode.value}'); // ThemeMode.light
    testConfig.dispose();

    print('\n=== Example completed successfully ===');
  } finally {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  }
}
