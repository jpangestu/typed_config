import 'dart:convert';
import 'dart:io' show File, FileSystemException;

import 'package:meta/meta.dart';
import 'package:typed_config/src/config_builder.dart';
import 'package:typed_config/src/config_engine.dart';
import 'package:typed_config/src/config_migrator.dart';

// TODO: remove deprecated in 1.0
@Deprecated('Use TypedConfig instead. Will be removed in 1.0.0.')
typedef Config = TypedConfig;

/// Base class for strongly-typed application config schemas.
///
/// Extends this class to define your configs:
/// ```dart
/// final class AppConfig(super.builder) extends TypedConfig {
///   final theme = builder.define('theme', 'system');
///   final volume = builder.define('volume', 0.8);
///   final audio = builder.group('audio', AudioConfig.new);
/// }
/// ```
abstract base class TypedConfig {
  /// The builder context used to define entries and groups for this config.
  @protected
  @visibleForTesting
  final ConfigBuilder builder;

  /// Creates a configuration schema bound to [builder].
  TypedConfig(this.builder);

  /// Key used in root storage to track schema version for migrations.
  static const String schemaVersionKey = 'schemaVersion';

  /// Loads configuration from [configFile], falling back to defaults if missing.
  ///
  /// Pass your [TypedConfig] definition class to [create] and add migration changes if needed:
  /// ```dart
  /// final config = await TypedConfig.initialize(
  ///   configFile: File('config.json'),
  ///   create: AppConfig.new, // Short for (builder) => AppConfig(builder)
  ///   schemaVersion: 2,
  ///   migrations: {
  ///     2: (migrator) {
  ///       migrator.rename(['oldKey'], ['newGroup', 'newKey'])
  ///       ...
  ///     }
  ///   }
  /// );
  /// ```
  ///
  /// Changes to configs are debounced by [debounceDuration] (defaulting to 300ms)
  /// before being atomically saved to disk.
  static Future<T> initialize<T extends TypedConfig>({
    required File configFile,
    required T Function(ConfigBuilder builder) create,
    bool saveDefaultValue = ConfigEngine.defaultSaveDefaultValue,
    int schemaVersion = 1,
    Map<int, MigrationHandler>? migrations,
    Duration debounceDuration = ConfigEngine.defaultDebounceDuration,
    void Function(String message)? onLog,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) async {
    var inMemoryCache = <String, dynamic>{};
    final fileExisted = await configFile.exists();

    // Load configs from configFile to inMemoryCache
    if (fileExisted) {
      try {
        final rawJson = await configFile.readAsString();
        final decodedJson = jsonDecode(rawJson);

        if (decodedJson is Map<String, dynamic>) {
          inMemoryCache = decodedJson;
          onLog?.call('[typed_config] Loaded configuration from ${configFile.path}');
        } else {
          onLog?.call('[typed_config] File content is not a JSON object. Starting with defaults.');
          await _quarantineFile(configFile, onLog: onLog, onError: onError);
          onError?.call(
            const FormatException('Config file content is not a JSON object.'),
            StackTrace.current,
          );
        }
      } catch (e, s) {
        onLog?.call('[typed_config] Failed to read ${configFile.path}. Starting with defaults.');
        await _quarantineFile(configFile, onLog: onLog, onError: onError);
        onError?.call(e, s);
      }
    } else {
      onLog?.call('[typed_config] Config file not found. Starting with defaults.');
    }

    final engine = ConfigEngine(
      storedConfigFile: configFile,
      inMemoryCache: inMemoryCache,
      saveDefaultValue: saveDefaultValue,
      debounceDuration: debounceDuration,
      onLog: onLog,
      onError: onError,
    );

    _runMigrations(
      engine: engine,
      schemaVersion: schemaVersion,
      migrations: migrations,
      isFirstSetup: !fileExisted || inMemoryCache.isEmpty,
      onLog: onLog,
      onError: onError,
    );

    final builder = ConfigBuilder(engine: engine, prefixPath: const []);
    final userConfig = create.call(builder);
    await engine.flush();

    return userConfig;
  }

  /// Creates an in-memory configuration instance without file persistence.
  ///
  /// Ideal for unit tests, headless environments, or transient application state:
  /// ```dart
  /// final testConfig = TypedConfig.inMemory(
  ///   create: AppConfig.new,
  ///   initialData: {'volume': 0.5},
  ///   schemaVersion: 2,
  ///   migrations: {
  ///     2: (migrator) {
  ///       migrator.rename(['volume'], ['audio', 'volume']);
  ///     },
  ///   },
  /// );
  /// ```
  static T inMemory<T extends TypedConfig>({
    required T Function(ConfigBuilder builder) create,
    Map<String, dynamic>? initialData,
    bool saveDefaultValue = ConfigEngine.defaultSaveDefaultValue,
    int schemaVersion = 1,
    Map<int, MigrationHandler>? migrations,
    Duration debounceDuration = ConfigEngine.defaultDebounceDuration,
    void Function(String message)? onLog,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) {
    // Copy to prevent outside callers from modifying the map directly (which would bypass change
    // listeners and writing to disk) and to ensure the map is mutable if const was passed.
    final inMemoryCache = initialData != null
        ? jsonDecode(jsonEncode(initialData)) as Map<String, dynamic>
        : <String, dynamic>{};
    onLog?.call('[typed_config] Initialized in-memory configuration.');

    final engine = ConfigEngine(
      inMemoryCache: inMemoryCache,
      saveDefaultValue: saveDefaultValue,
      debounceDuration: debounceDuration,
      onLog: onLog,
      onError: onError,
    );

    _runMigrations(
      engine: engine,
      schemaVersion: schemaVersion,
      migrations: migrations,
      isFirstSetup: initialData == null,
      onLog: onLog,
      onError: onError,
    );

    final builder = ConfigBuilder(engine: engine, prefixPath: const []);

    return create.call(builder);
  }

  static Future<void> _quarantineFile(
    File configFile, {
    void Function(String message)? onLog,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) async {
    if (!await configFile.exists()) return;

    // Delete any older .corrupt file for this specific config file so only 1 exists
    try {
      if (await configFile.parent.exists()) {
        final targetFile = configFile.absolute;
        final dir = targetFile.parent;
        final targetPath = targetFile.path.replaceAll(r'\', '/');
        final prefix = '$targetPath.';
        final oldCorruptFiles = dir.listSync().whereType<File>().where(
              (f) => f.path.replaceAll(r'\', '/').startsWith(prefix) && f.path.endsWith('.corrupt'),
            );

        for (final oldFile in oldCorruptFiles) {
          try {
            await oldFile.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}

    final now = DateTime.now();
    String pad(int n) => n.toString().padLeft(2, '0');
    final timestamp =
        '${now.year}${pad(now.month)}${pad(now.day)}_${pad(now.hour)}${pad(now.minute)}${pad(now.second)}';
    final corruptFile = File('${configFile.path}.$timestamp.corrupt');

    try {
      try {
        await configFile.rename(corruptFile.path);
      } on FileSystemException {
        // Fallback for file lock contention (especially on Windows)
        await configFile.copy(corruptFile.path);
        await configFile.delete();
      }
      onLog?.call('[typed_config] Quarantined corrupted config file to ${corruptFile.path}');
    } catch (e, s) {
      onLog?.call('[typed_config] Failed to quarantine corrupt config file: $e');
      onError?.call(e, s);
    }
  }

  static void _runMigrations({
    required ConfigEngine engine,
    required int schemaVersion,
    required Map<int, MigrationHandler>? migrations,
    bool isFirstSetup = false,
    void Function(String message)? onLog,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) {
    if (isFirstSetup) {
      engine.writeFirst(schemaVersionKey, schemaVersion);
      return; // Exit. Migration is not needed
    }

    final currentSchemaVersion = (engine.read([schemaVersionKey]) as num?)?.toInt() ?? 1;

    if (currentSchemaVersion < schemaVersion) {
      for (int i = currentSchemaVersion + 1; i <= schemaVersion; i++) {
        final migrator = migrations?[i];
        if (migrator != null) {
          try {
            migrator.call(ConfigMigrator(configEngine: engine, fromVersion: i - 1, toVersion: i));
            onLog?.call('[typed_config] Migrated config schema from v${i - 1} to v$i.');
          } catch (e, s) {
            onLog?.call('[typed_config] Migration from v${i - 1} to v$i failed: $e');
            onError?.call(e, s);
            rethrow;
          }
        }

        engine.write([schemaVersionKey], i);
      }
    } else if (currentSchemaVersion > schemaVersion) {
      onLog?.call(
        '[typed_config] Config schema version ($currentSchemaVersion) is newer than current version ($schemaVersion).',
      );
    }

    // Strictly guarantees schemaVersion is at index 0 of the JSON map
    final targetVersion =
        currentSchemaVersion < schemaVersion ? schemaVersion : currentSchemaVersion;
    engine.writeFirst(schemaVersionKey, targetVersion);
  }

  /// Immediately persists all pending in-memory configuration changes to disk.
  Future<void> flush() async {
    await builder.engine.flush();
  }

  /// Clears all stored in-memory configuration overrides and immediately saves to disk.
  /// Preserve schema version.
  Future<void> resetAll() async {
    final version = builder.engine.read([schemaVersionKey]);
    builder.engine.resetAll();
    if (version != null) {
      builder.engine.writeFirst(schemaVersionKey, version);
    }
    await flush();
  }

  /// Releases active timers, watchers, and streams, saving any pending changes synchronously.
  void dispose() {
    builder.engine.dispose();
  }
}
