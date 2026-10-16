import 'dart:convert';
import 'dart:io' show File;

import 'package:typed_config/src/config_builder.dart';
import 'package:typed_config/src/config_engine.dart';

/// Base class for strongly-typed application configuration schemas.
///
/// Subclass [Config] to declare settings and nested groups using [ConfigBuilder]:
/// ```dart
/// class AppConfig(super.builder) extends Config {
///   final theme = builder.define('theme', 'system');
///   final volume = builder.define('volume', 0.8);
///   final audio = builder.group('audio', AudioConfig.new);
/// }
/// ```
class Config {
  /// The builder context used to define entries and groups for this config.
  final ConfigBuilder builder;

  /// Creates a configuration instance bound to [builder].
  Config(this.builder);

  /// Loads configuration from [configFile], falling back to defaults if missing.
  ///
  /// Pass [create] as the constructor tear-off for your [Config] subclass:
  /// ```dart
  /// final config = await Config.initialize(
  ///   configFile: File('config.json'),
  ///   create: AppConfig.new,
  /// );
  /// ```
  ///
  /// Changes to settings are debounced by [debounceDuration] (defaulting to 300ms)
  /// before being atomically saved to disk.
  static Future<T> initialize<T extends Config>({
    required File configFile,
    required T Function(ConfigBuilder builder) create,
    Duration? debounceDuration,
    void Function(String message)? onLog,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) async {
    var inMemoryCache = <String, dynamic>{};

    // Load configs from configFile to inMemoryCache
    if (await configFile.exists()) {
      try {
        final rawJson = await configFile.readAsString();
        final decodedJson = jsonDecode(rawJson);

        if (decodedJson is Map<String, dynamic>) {
          inMemoryCache = decodedJson;
          onLog?.call('[typed_config] Loaded configuration from ${configFile.path}');
        } else {
          onLog?.call('[typed_config] File content is not a JSON object. Starting with defaults.');
        }
      } catch (e, s) {
        onLog?.call('[typed_config] Failed to read ${configFile.path}. Starting with defaults.');
        onError?.call(e, s);
      }
    } else {
      onLog?.call('[typed_config] Config file not found. Starting with defaults.');
    }

    final engine = ConfigEngine(
      storedConfigFile: configFile,
      inMemoryCache: inMemoryCache,
      debounceDuration: debounceDuration,
      onLog: onLog,
      onError: onError,
    );

    final builder = ConfigBuilder(engine: engine, prefixPath: const []);

    return create.call(builder);
  }

  /// Creates an in-memory configuration instance without file persistence.
  ///
  /// Ideal for unit tests, headless environments, or transient application state:
  /// ```dart
  /// final testConfig = Config.inMemory(
  ///   create: AppConfig.new,
  ///   initialData: {'volume': 0.5},
  /// );
  /// ```
  static T inMemory<T extends Config>({
    required T Function(ConfigBuilder builder) create,
    Map<String, dynamic>? initialData,
    Duration? debounceDuration,
    void Function(String message)? onLog,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) {
    // Copy to prevent outside callers from modifying the map directly (which would bypass change
    // listeners and writing to disk) and to ensure the map is mutable if const was passed.
    final inMemoryCache = initialData != null
        ? Map<String, dynamic>.of(initialData)
        : <String, dynamic>{};
    onLog?.call('[typed_config] Initialized in-memory configuration.');

    final engine = ConfigEngine(
      inMemoryCache: inMemoryCache,
      debounceDuration: debounceDuration,
      onLog: onLog,
      onError: onError,
    );

    final builder = ConfigBuilder(engine: engine, prefixPath: const []);

    return create.call(builder);
  }

  /// Immediately persists all pending in-memory configuration changes to disk.
  Future<void> flush() async {
    await builder.engine.flush();
  }

  /// Clears all stored in-memory configuration overrides and immediately saves to disk.
  Future<void> resetAll() async {
    builder.engine.resetAll();
    await flush();
  }

  /// Releases active timers, watchers, and streams, saving any pending changes synchronously.
  void dispose() {
    builder.engine.dispose();
  }
}
