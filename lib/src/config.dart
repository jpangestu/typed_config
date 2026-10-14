import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';

import 'config_builder.dart';
import 'config_engine.dart';
import 'config_entry.dart';
import 'config_migration.dart' as migration;
import 'config_migration.dart' show ConfigMigrator;

/// Base class for strongly-typed application configurations.
///
/// Subclass [Config] using a primary constructor that accepts [ConfigBuilder] to
/// declare your application settings:
///
/// ```dart
/// class AppConfig(ConfigBuilder builder) extends Config(builder) {
///   final theme = builder.define('theme', 'system');
///   final volume = builder.define('volume', 0.8);
/// }
/// ```
///
/// Load once asynchronously at startup using [Config.initialize] (or [Config.inMemory]
/// for tests). Once initialized, all entries provide synchronous reads, immediate
/// in-memory writes, and debounced disk persistence.
class Config {
  /// Key used in JSON storage to track the current configuration schema version.
  static const String schemaVersionKey = migration.schemaVersionKey;

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
  @internal
  Map<String, dynamic> get cache => engine.cache;

  /// Broadcast stream controller notifying key mutations.
  @internal
  StreamController<String> get keyChanges => engine.keyChanges;

  /// Custom logger callback.
  void Function(String message)? get onLog => _engine?.onLog;

  /// Custom error handler callback.
  void Function(Object error, StackTrace stackTrace)? get onError => _engine?.onError;

  /// Whether this config instance has been disposed.
  bool get isDisposed => _engine?.isDisposed ?? false;

  /// The namespace prefix of this configuration group, or empty string `''` for root.
  final String prefix;

  /// The builder for declaring configuration entries within this group's namespace.
  ConfigBuilder get builder => ConfigBuilder(engine, prefix);

  /// Creates a [Config] instance. When passed a [ConfigBuilder], binds directly to its engine and prefix.
  Config([ConfigBuilder? initialBuilder]) : prefix = initialBuilder?.prefix ?? '' {
    if (initialBuilder != null) {
      _engine = initialBuilder.engine;
    }
  }

  // ==============================================================================================
  // Direct Key Access & Overrides
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
    final engine = await ConfigEngine.load(
      configFile,
      schemaVersion: schemaVersion,
      migrations: migrations,
      onLog: onLog,
      onError: onError,
    );
    final builder = ConfigBuilder(engine);
    final instance = factory(builder)..attachEngine(engine);

    if (engine.isDirty) {
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
    final engine = ConfigEngine.inMemory(initialCache);
    final builder = ConfigBuilder(engine);
    return factory(builder)..attachEngine(engine);
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
