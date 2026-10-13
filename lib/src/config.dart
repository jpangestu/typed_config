import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import 'config_builder.dart';
import 'config_engine.dart';
import 'config_entry.dart';
import 'config_migration.dart';

/// Central application configuration engine managing in-memory cache,
/// debounced atomic disk writes, and cross-platform file synchronization.
///
/// Subclass this or instantiate directly to define application settings.
class Config {
  /// Key used in JSON storage to track the current configuration schema version.
  static const String schemaVersionKey = 'schemaVersion';

  ConfigEngine? _engine;

  /// Internal lifecycle hook to attach the backing [ConfigEngine].
  @internal
  void attachEngine(ConfigEngine engine) {
    _engine = engine;
  }

  /// The active [ConfigEngine] instance.
  @internal
  ConfigEngine get engine {
    final e = _engine;
    if (e == null) {
      throw StateError('Config instance is not attached to a ConfigEngine.');
    }
    return e;
  }

  /// The underlying backing file on disk, or null for in-memory configs.
  File? get file => _engine?.file;

  /// The active in-memory cache of flattened configuration entries.
  Map<String, dynamic> get cache => engine.cache;

  /// Broadcast stream controller notifying key mutations.
  StreamController<String> get keyChanges => engine.keyChanges;

  /// Custom logger callback.
  void Function(String message)? get onLog => _engine?.onLog;

  /// Custom error handler callback.
  void Function(Object error, StackTrace stackTrace)? get onError => _engine?.onError;

  /// Whether this config instance has been disposed.
  bool get isDisposed => _engine?.isDisposed ?? false;

  /// The root builder for declaring configuration entries.
  ConfigBuilder get builder => ConfigBuilder(engine);

  /// Creates a [Config] instance. When passed a [ConfigBuilder], binds directly to its engine.
  Config([ConfigBuilder? initialBuilder]) {
    if (initialBuilder != null) {
      _engine = initialBuilder.engine;
    }
  }

  // ==============================================================================================
  // Core Engine Operations
  // ==============================================================================================

  /// Whether [entry] has an explicitly stored value in the cache.
  bool contains<T>(ConfigEntry<T> entry) => engine.containsKey(entry.key);

  /// Synchronously returns raw stored value for [key].
  dynamic readRaw(String key) => engine.readRaw(key);

  /// Stores [value] for [key] in memory and schedules a debounced save to disk.
  void writeRaw(String key, dynamic value) => engine.writeRaw(key, value);

  /// Removes [key] from the cache and schedules saving to disk.
  void resetKey(String key) => engine.resetKey(key);

  /// Clears all configuration overrides, reverts all entries to defaults,
  /// and flushes to disk immediately.
  Future<void> resetAll() => engine.resetAll();

  /// Broadcast stream emitting events when [key] or wildcard `'*'` changes.
  Stream<String> watchKey(String key) => engine.watchKey(key);

  // ==============================================================================================
  // Disk Writes & External Reload
  // ==============================================================================================

  /// Immediately writes in-memory configuration changes to disk without waiting for the debounce timer.
  Future<void> flush() => engine.flush();

  /// Starts desktop external file watcher.
  void startWatcher() => engine.startWatcher();

  /// Re-reads configuration from disk, updating the cache and notifying listeners of changes.
  Future<void> reloadFromDisk() => engine.reloadFromDisk();

  // ==============================================================================================
  // Factory Loaders
  // ==============================================================================================

  /// Asynchronously initializes a typed [Config] subclass from [configFile].
  ///
  /// Passes a root [ConfigBuilder] to [factory] (e.g. `AppConfig.new`).
  /// Automatically runs [migrations] sequentially if the file version is older than [schemaVersion].
  /// If damaged, quarantines the file to `<file>.corrupt` and initializes clean defaults.
  static Future<T> initialize<T extends Config>(
    T Function(ConfigBuilder builder) factory,
    File configFile, {
    int schemaVersion = 1,
    Map<int, ConfigMigrator>? migrations,
    void Function(String message)? onLog,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) async {
    if (schemaVersion < 1) {
      throw ArgumentError.value(
        schemaVersion,
        'schemaVersion',
        'Schema version must be at least 1.',
      );
    }

    final logger =
        onLog ??
        (!bool.fromEnvironment('dart.vm.product') ? (msg) => print('[Config] $msg') : null);

    Map<String, dynamic> cache;
    bool shouldFlushImmediately = false;

    if (!configFile.existsSync()) {
      cache = <String, dynamic>{schemaVersionKey: schemaVersion};
      shouldFlushImmediately = true;
    } else {
      try {
        final content = await configFile.readAsString();
        final decoded = jsonDecode(content);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Config JSON is not an object');
        }

        final flatDecoded = flattenConfigMap(decoded);
        final migrationResult = migrateConfigData(
          data: flatDecoded,
          targetVersion: schemaVersion,
          migrations: migrations,
          onLog: logger,
          onError: onError,
        );

        cache = migrationResult.data;
        if (migrationResult.didMigrate) {
          shouldFlushImmediately = true;
          logger?.call(
            'Migrated config schema from v${migrationResult.fromVersion} to v${migrationResult.toVersion}.',
          );
        }
      } catch (e, s) {
        await ConfigEngine.quarantineFile(configFile, logger);
        cache = <String, dynamic>{schemaVersionKey: schemaVersion};
        shouldFlushImmediately = true;
        if (onError != null) {
          onError(e, s);
        } else {
          print('[Config ERROR] Failed to load existing config. Resetting to defaults.: $e');
        }
      }
    }

    final engine = ConfigEngine(file: configFile, cache: cache, onLog: onLog, onError: onError);
    final builder = ConfigBuilder(engine);
    final instance = factory(builder);
    instance.attachEngine(engine);

    if (shouldFlushImmediately) {
      await instance.flush();
    }
    instance.startWatcher();
    return instance;
  }

  /// Instantiates a typed in-memory configuration without file persistence (ideal for tests).
  static T inMemory<T extends Config>(
    T Function(ConfigBuilder builder) factory, [
    Map<String, dynamic>? initialCache,
  ]) {
    final engine = ConfigEngine(
      cache: initialCache != null ? flattenConfigMap(initialCache) : <String, dynamic>{},
    );
    final builder = ConfigBuilder(engine);
    final instance = factory(builder);
    instance.attachEngine(engine);
    return instance;
  }

  /// Releases active timers, file watchers, and streams.
  ///
  /// Synchronously saves any pending dirty changes to disk before closing to
  /// prevent data loss on fast application exit.
  void dispose() => _engine?.dispose();

  /// Returns an unmodifiable snapshot map of all configuration entries in memory.
  Map<String, dynamic> toFlatJson() => engine.toFlatJson();

  /// Returns the nested unflattened JSON map as it would appear on disk.
  Map<String, dynamic> toJson() => engine.toJson();
}
