import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';

import 'config_builder.dart';
import 'config_engine.dart';
import 'config_entry.dart';
import 'config_migration.dart' as migration;
import 'config_migration.dart' show ConfigMigrator, unflattenConfigMap;

/// Base class for strongly-typed application configurations.
///
/// Subclass [Config] using a constructor that accepts [ConfigBuilder] and
/// forwards it to `super(builder)`.
///
/// Entries can be initialized eagerly in the constructor initializer list
/// (which validates keys immediately at startup):
///
/// ```dart
/// class AppConfig extends Config {
///   AppConfig(super.builder)
///       : theme = builder.define('theme', 'system'),
///         volume = builder.define('volume', 0.8);
///
///   final ConfigEntry<String> theme;
///   final ConfigEntry<double> volume;
/// }
/// ```
///
/// Or declared concisely using `late final`:
///
/// ```dart
/// class AppConfig extends Config {
///   AppConfig(super.builder);
///
///   late final theme = builder.define('theme', 'system');
///   late final volume = builder.define('volume', 0.8);
/// }
/// ```
///
/// Load once asynchronously at startup using [Config.initialize] (or [Config.inMemory]
/// for tests). Once initialized, all entries provide synchronous reads, immediate
/// in-memory writes, and debounced disk persistence.
class Config {
  /// Key used in JSON storage to track the current configuration schema version.
  static const String schemaVersionKey = migration.schemaVersionKey;

  final ConfigEngine _engine;

  /// The active [ConfigEngine] instance.
  @internal
  ConfigEngine get engine => _engine;

  /// The underlying backing file on disk, or null for in-memory configs.
  File? get file => _engine.file;

  /// The active in-memory cache of flattened configuration entries.
  @internal
  Map<String, dynamic> get cache => _engine.cache;

  /// Broadcast stream controller notifying key mutations.
  @internal
  StreamController<String> get keyChanges => _engine.keyChanges;

  /// Custom logger callback.
  void Function(String message)? get onLog => _engine.onLog;

  /// Custom error handler callback.
  void Function(Object error, StackTrace stackTrace)? get onError => _engine.onError;

  /// Whether this config instance has been disposed.
  bool get isDisposed => _engine.isDisposed;

  /// The namespace prefix of this configuration group, or empty string `''` for root.
  final String prefix;

  /// The builder for declaring configuration entries within this group's namespace.
  final ConfigBuilder builder;

  /// Creates a [Config] instance bound to [builder]'s engine and prefix.
  Config(this.builder)
      : _engine = builder.engine,
        prefix = builder.prefix;

  String _scopedKey(String key) {
    if (prefix.isEmpty) return key;
    if (key.isEmpty) return prefix;
    return '$prefix.$key';
  }

  String _unscopeKey(String fullKey) {
    if (prefix.isEmpty || fullKey == '*') return fullKey;
    if (fullKey == prefix) return '*';
    final scopedPrefix = '$prefix.';
    if (fullKey.startsWith(scopedPrefix)) {
      return fullKey.substring(scopedPrefix.length);
    }
    // An ancestor of `prefix` was modified/reset
    if (prefix.startsWith('$fullKey.')) {
      return '*';
    }
    return fullKey;
  }

  // ==============================================================================================
  // Direct Key Access & Overrides
  // ==============================================================================================

  /// Whether [entry] belongs to this configuration scope and has an explicitly stored value.
  bool contains<T>(ConfigEntry<T> entry) {
    if (!identical(entry.engine, _engine)) return false;
    if (prefix.isNotEmpty && entry.key != prefix && !entry.key.startsWith('$prefix.')) {
      return false;
    }
    return _engine.containsKey(entry.key);
  }

  /// Synchronously returns raw stored value for [key] (scoped to [prefix] if non-empty).
  dynamic readRaw(String key) => _engine.readRaw(_scopedKey(key));

  /// Stores [value] for [key] (scoped to [prefix] if non-empty) in memory and schedules a debounced save to disk.
  void writeRaw(String key, dynamic value) => _engine.writeRaw(_scopedKey(key), value);

  /// Removes [key] (scoped to [prefix] if non-empty) from the cache and schedules saving to disk.
  void resetKey(String key) => _engine.resetKey(_scopedKey(key));

  /// Clears all configuration overrides in this scope, reverts entries to defaults,
  /// and flushes to disk immediately.
  Future<void> resetAll() async {
    if (prefix.isEmpty) {
      await _engine.resetAll();
    } else {
      _engine.resetKey(prefix, scheduleSave: false);
      await _engine.flush();
    }
  }

  /// Broadcast stream emitting relative keys when [key] or wildcard `'*'` changes.
  Stream<String> watchKey(String key) {
    if (prefix.isEmpty) {
      return _engine.watchKey(key);
    }
    final target = key == '*' ? prefix : _scopedKey(key);
    return _engine.watchKey(target).map(_unscopeKey);
  }

  // ==============================================================================================
  // Disk Writes & External Reload
  // ==============================================================================================

  /// Immediately writes in-memory configuration changes to disk without waiting for the debounce timer.
  Future<void> flush() => _engine.flush();

  /// Starts desktop external file watcher on the root configuration instance.
  ///
  /// Throws a [StateError] if called on a scoped child group.
  void startWatcher() {
    if (prefix.isNotEmpty) {
      throw StateError(
        'Cannot call startWatcher() on scoped group "$prefix". Call it on the root Config instance.',
      );
    }
    _engine.startWatcher();
  }

  /// Re-reads configuration from disk, updating the cache and notifying listeners of changes.
  Future<void> reloadFromDisk() => _engine.reloadFromDisk();

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
    final instance = factory(ConfigBuilder(engine));

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
    return factory(ConfigBuilder(engine));
  }

  /// Releases active timers, file watchers, and streams on the root configuration instance.
  ///
  /// Synchronously saves any pending dirty changes to disk before closing to
  /// prevent data loss on fast application exit.
  /// Throws a [StateError] if called on a scoped child group.
  void dispose() {
    if (prefix.isNotEmpty) {
      throw StateError(
        'Cannot dispose scoped group "$prefix". Call dispose() on the root Config instance.',
      );
    }
    _engine.dispose();
  }

  /// Returns an unmodifiable snapshot map of configuration entries in memory for this scope.
  Map<String, dynamic> toFlatJson() {
    if (prefix.isEmpty) return _engine.toFlatJson();
    final scopedPrefix = '$prefix.';
    final scoped = <String, dynamic>{};
    for (final entry in _engine.cache.entries) {
      if (entry.key.startsWith(scopedPrefix)) {
        scoped[entry.key.substring(scopedPrefix.length)] = entry.value;
      }
    }
    return Map<String, dynamic>.unmodifiable(scoped);
  }

  /// Returns the nested unflattened JSON map for this scope.
  Map<String, dynamic> toJson() {
    if (prefix.isEmpty) return _engine.toJson();
    return unflattenConfigMap(toFlatJson());
  }
}
