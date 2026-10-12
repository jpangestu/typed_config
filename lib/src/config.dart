import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'config_builder.dart';
import 'config_entry.dart';

/// Function signature for migrating raw configuration JSON maps between schema versions.
typedef ConfigMigrator = void Function(Map<String, dynamic> raw);

const MapEquality<String, dynamic> _mapEquality = MapEquality<String, dynamic>();

/// Central application configuration engine managing in-memory cache,
/// debounced atomic disk writes, and cross-platform file synchronization.
///
/// Subclass this or instantiate directly to define application settings.
class Config {
  /// Key used in JSON storage to track the current configuration schema version.
  static const String schemaVersionKey = 'schemaVersion';

  static const bool _kDebugMode = !bool.fromEnvironment('dart.vm.product');

  File? _file;
  Map<String, dynamic>? _cache;
  StreamController<String>? _keyChanges;
  void Function(String message)? _onLog;
  void Function(Object error, StackTrace stackTrace)? _onError;

  /// The underlying backing file on disk, or null for in-memory configs.
  File? get file => _file;

  /// The active in-memory cache of flattened configuration entries.
  Map<String, dynamic> get cache => _cache ??= <String, dynamic>{};

  /// Broadcast stream controller notifying key mutations.
  StreamController<String> get keyChanges => _keyChanges ??= StreamController<String>.broadcast();

  /// Custom logger callback.
  void Function(String message)? get onLog => _onLog;

  /// Custom error handler callback.
  void Function(Object error, StackTrace stackTrace)? get onError => _onError;

  Timer? _debounceTimer;
  Timer? _watcherDebounceTimer;
  Completer<void>? _currentWrite;
  Completer<void>? _nextWrite;
  StreamSubscription<FileSystemEvent>? _fileWatcherSubscription;
  DateTime? _lastInternalWriteTime;

  ConfigBuilder? _builder;

  /// The root builder for declaring configuration entries.
  ConfigBuilder get builder => _builder ??= ConfigBuilder('', this);

  /// Creates a [Config] instance. When passed a [ConfigBuilder], binds directly to it.
  Config([ConfigBuilder? initialBuilder]) {
    if (initialBuilder != null) {
      initFromBuilder(initialBuilder);
      initialBuilder.bind(this);
    }
  }

  /// Internal lifecycle hook to bind state from a [ConfigBuilder].
  @internal
  void initFromBuilder(ConfigBuilder b) {
    _file = b.file;
    _cache = b.cache;
    _keyChanges = b.keyChanges;
    _onLog = b.onLog;
    _onError = b.onError;
    _builder = b;
  }

  void _log(String message) {
    if (onLog != null) {
      onLog!(message);
    } else if (_kDebugMode) {
      print('[Config] $message');
    }
  }

  /// Emits error details through [onError] or [print].
  void _logError(String message, Object error, StackTrace stackTrace) {
    if (onError != null) {
      onError!(error, stackTrace);
    } else {
      print('[Config ERROR] $message: $error');
    }
  }

  /// Broadcasts a change event for [key] if the stream controller is not closed.
  void _notifyKey(String key) {
    if (!keyChanges.isClosed) {
      keyChanges.add(key);
    }
  }

  // ==============================================================================================
  // Core Engine Operations
  // ==============================================================================================

  /// Whether [entry] has an explicitly stored value in the cache.
  bool contains<T>(ConfigEntry<T> entry) => cache.containsKey(entry.key);

  /// Synchronously returns raw stored value for [key].
  dynamic readRaw(String key) => cache[key];

  /// Stores [value] for [key] in memory and schedules a debounced save to disk.
  void writeRaw(String key, dynamic value) {
    dynamic serialized = value;
    if (serialized is List) {
      serialized = List<dynamic>.unmodifiable(serialized);
    } else if (serialized is Map) {
      serialized = Map<String, dynamic>.unmodifiable(serialized);
    }
    if (cache.containsKey(key) && cache[key] == serialized) {
      return;
    }
    cache[key] = serialized;
    _notifyKey(key);
    _scheduleSave();
  }

  /// Removes [key] from the cache and schedules saving to disk.
  void resetKey(String key) {
    if (!cache.containsKey(key)) return;
    cache.remove(key);
    _notifyKey(key);
    _scheduleSave();
  }

  /// Clears all configuration overrides, reverts all entries to defaults,
  /// and flushes to disk immediately.
  Future<void> resetAll() async {
    cache.clear();
    _notifyKey('*');
    _scheduleSave();
    await flush();
  }

  /// Broadcast stream emitting events when [key] or wildcard `'*'` changes.
  Stream<String> watchKey(String key) {
    return keyChanges.stream.where((changedKey) => changedKey == key || changedKey == '*');
  }

  // ==============================================================================================
  // Disk Writes & External Reload
  // ==============================================================================================

  /// Schedules saving to disk after 300ms of inactivity.
  void _scheduleSave() {
    if (file == null) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () => unawaited(flush()));
  }

  /// Immediately writes in-memory configuration changes to disk without waiting for the debounce timer.
  Future<void> flush() {
    final targetFile = file;
    if (targetFile == null) return Future.value();

    _debounceTimer?.cancel();

    if (_currentWrite != null) {
      _nextWrite ??= Completer<void>();
      return _nextWrite!.future;
    }

    final completer = Completer<void>();
    _currentWrite = completer;

    () async {
      try {
        final flatMap = Map<String, dynamic>.from(cache);
        final nestedMap = unflattenConfigMap(flatMap);
        final jsonString = JsonEncoder.withIndent('  ', (o) => o.toString()).convert(nestedMap);

        if (!targetFile.parent.existsSync()) {
          targetFile.parent.createSync(recursive: true);
        }

        final tempFile = File('${targetFile.path}.$pid.tmp');
        await tempFile.writeAsString(jsonString, flush: true);

        try {
          await tempFile.rename(targetFile.path);
        } on FileSystemException {
          // Fallback for Windows lock contention
          await tempFile.copy(targetFile.path);
          try {
            await tempFile.delete();
          } catch (_) {}
        }

        _lastInternalWriteTime = DateTime.now();
        _log('Successfully written to disk.');
        completer.complete();
      } catch (e, s) {
        _logError('Failed to write config to disk', e, s);
        completer.completeError(e, s);
      } finally {
        _currentWrite = null;
        if (_nextWrite != null) {
          final next = _nextWrite!;
          _nextWrite = null;
          flush().then(next.complete, onError: next.completeError);
        }
      }
    }();

    return completer.future;
  }

  /// Starts desktop external file watcher.
  void startWatcher() {
    final targetFile = file;
    if (targetFile == null) return;
    if (!FileSystemEntity.isWatchSupported) return;
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;

    try {
      _fileWatcherSubscription = targetFile.parent.watch().listen((event) {
        if (p.basename(event.path) == p.basename(targetFile.path) &&
            event.type != FileSystemEvent.delete) {
          final lastWrite = _lastInternalWriteTime;
          if (lastWrite != null && DateTime.now().difference(lastWrite).inMilliseconds < 1000) {
            // Ignore internal write echo
            return;
          }
          _watcherDebounceTimer?.cancel();
          _watcherDebounceTimer = Timer(const Duration(milliseconds: 150), () async {
            if (!targetFile.existsSync()) return;
            try {
              final content = await targetFile.readAsString();
              final decoded = jsonDecode(content);
              if (decoded is Map<String, dynamic>) {
                final flatDecoded = flattenConfigMap(decoded);
                if (_mapEquality.equals(cache, flatDecoded)) return;
                final changedKeys = <String>{};
                for (final entry in flatDecoded.entries) {
                  if (cache[entry.key] != entry.value) {
                    changedKeys.add(entry.key);
                  }
                }
                for (final key in cache.keys) {
                  if (!flatDecoded.containsKey(key)) {
                    changedKeys.add(key);
                  }
                }
                cache.clear();
                cache.addAll(flatDecoded);
                for (final k in changedKeys) {
                  _notifyKey(k);
                }
                _log('Reloaded from disk modification: ${changedKeys.join(", ")}');
              }
            } catch (e) {
              _log('Ignored corrupted external config.json update: $e');
            }
          });
        }
      });
    } catch (e) {
      _log('Could not start file watcher: $e');
    }
  }

  /// Re-reads configuration from disk, updating the cache and notifying listeners of changes.
  Future<void> reloadFromDisk() async {
    final targetFile = file;
    if (targetFile == null || !targetFile.existsSync()) return;

    try {
      final content = await targetFile.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Config JSON is not an object');
      }

      final flatDecoded = flattenConfigMap(decoded);
      final changedKeys = <String>{};

      for (final entry in flatDecoded.entries) {
        if (!cache.containsKey(entry.key) || cache[entry.key] != entry.value) {
          changedKeys.add(entry.key);
        }
      }
      for (final key in cache.keys) {
        if (!flatDecoded.containsKey(key)) {
          changedKeys.add(key);
        }
      }

      cache.clear();
      cache.addAll(flatDecoded);

      for (final key in changedKeys) {
        _notifyKey(key);
      }
      _log('Reloaded from disk.');
    } catch (e, s) {
      _logError('Failed to reload config from disk', e, s);
    }
  }

  /// Safely renames or copies a corrupted file to [file.path].corrupt.
  static Future<void> _quarantineFile(File file, void Function(String message)? log) async {
    if (!file.existsSync()) return;
    try {
      final corruptFile = File('${file.path}.corrupt');
      if (corruptFile.existsSync()) {
        try {
          await corruptFile.delete();
        } catch (_) {}
      }
      try {
        await file.rename(corruptFile.path);
      } on FileSystemException {
        // Fallback for Windows file lock contention
        await file.copy(corruptFile.path);
        try {
          await file.delete();
        } catch (_) {}
      }
      log?.call('Quarantined corrupt config file to: ${corruptFile.path}');
    } catch (e) {
      log?.call('Failed to quarantine corrupt config file: $e');
    }
  }

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
    final logger = onLog ?? (_kDebugMode ? (msg) => print('[Config] $msg') : null);

    if (!configFile.existsSync()) {
      final initialData = <String, dynamic>{schemaVersionKey: schemaVersion};
      final builder = ConfigBuilder.initialize(
        prefix: '',
        file: configFile,
        cache: initialData,
        onLog: onLog,
        onError: onError,
      );
      final instance = factory(builder);
      instance.initFromBuilder(builder);
      builder.bind(instance);
      await instance.flush();
      instance.startWatcher();
      return instance;
    }

    try {
      final content = await configFile.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Config JSON is not an object');
      }

      final flatDecoded = flattenConfigMap(decoded);
      final fileVersion = (flatDecoded[schemaVersionKey] as num?)?.toInt() ?? 1;
      bool needsFlush = false;

      if (fileVersion < schemaVersion) {
        if (migrations != null) {
          for (int v = fileVersion + 1; v <= schemaVersion; v++) {
            final migrator = migrations[v];
            if (migrator != null) {
              try {
                migrator(flatDecoded);
              } catch (e, s) {
                logger?.call('Migration to schema version v$v failed: $e');
                onError?.call(e, s);
                rethrow;
              }
            }
          }
        }
        flatDecoded[schemaVersionKey] = schemaVersion;
        needsFlush = true;
      } else if (!flatDecoded.containsKey(schemaVersionKey)) {
        flatDecoded[schemaVersionKey] = schemaVersion;
        needsFlush = true;
      } else if (fileVersion > schemaVersion) {
        logger?.call(
          'Config schema version ($fileVersion) is newer than current version ($schemaVersion).',
        );
      }

      final builder = ConfigBuilder.initialize(
        prefix: '',
        file: configFile,
        cache: flatDecoded,
        onLog: onLog,
        onError: onError,
      );
      final instance = factory(builder);
      instance.initFromBuilder(builder);
      builder.bind(instance);

      if (needsFlush) {
        await instance.flush();
        instance._log('Migrated config schema from v$fileVersion to v$schemaVersion.');
      }
      instance.startWatcher();
      return instance;
    } catch (e, s) {
      await _quarantineFile(configFile, logger);
      final initialData = <String, dynamic>{schemaVersionKey: schemaVersion};
      final builder = ConfigBuilder.initialize(
        prefix: '',
        file: configFile,
        cache: initialData,
        onLog: onLog,
        onError: onError,
      );
      final instance = factory(builder);
      instance.initFromBuilder(builder);
      builder.bind(instance);
      instance._logError('Failed to load existing config. Resetting to defaults.', e, s);
      await instance.flush();
      instance.startWatcher();
      return instance;
    }
  }

  /// Instantiates a typed in-memory configuration without file persistence (ideal for tests).
  static T inMemory<T extends Config>(
    T Function(ConfigBuilder builder) factory, [
    Map<String, dynamic>? initialCache,
  ]) {
    final builder = ConfigBuilder.initialize(
      prefix: '',
      cache: initialCache != null ? flattenConfigMap(initialCache) : <String, dynamic>{},
    );
    final instance = factory(builder);
    instance.initFromBuilder(builder);
    builder.bind(instance);
    return instance;
  }

  /// Releases active timers, file watchers, and streams.
  ///
  /// Synchronously saves any pending dirty changes to disk before closing to
  /// prevent data loss on fast application exit.
  void dispose() {
    if (_debounceTimer?.isActive ?? false) {
      _debounceTimer?.cancel();
      final targetFile = file;
      if (targetFile != null) {
        try {
          if (!targetFile.parent.existsSync()) {
            targetFile.parent.createSync(recursive: true);
          }
          final jsonStr = JsonEncoder.withIndent(
            '  ',
            (o) => o.toString(),
          ).convert(unflattenConfigMap(cache));
          targetFile.writeAsStringSync(jsonStr, flush: true);
          _log('Synchronously written to disk on dispose.');
        } catch (e, s) {
          _logError('Failed to write config on dispose', e, s);
        }
      }
    }
    _watcherDebounceTimer?.cancel();
    _fileWatcherSubscription?.cancel();
    keyChanges.close();
  }

  /// Returns an unmodifiable snapshot map of all configuration entries in memory.
  Map<String, dynamic> toFlatJson() => Map<String, dynamic>.unmodifiable(cache);

  /// Returns the nested unflattened JSON map as it would appear on disk.
  Map<String, dynamic> toJson() => unflattenConfigMap(cache);
}

/// Recursively flattens a nested map into a flat map with dot-separated keys.
Map<String, dynamic> flattenConfigMap(Map<String, dynamic> nested, [String prefix = '']) {
  final result = <String, dynamic>{};
  for (final entry in nested.entries) {
    final fullKey = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
    final val = entry.value;
    if (val is Map<String, dynamic>) {
      result.addAll(flattenConfigMap(val, fullKey));
    } else if (val is Map) {
      result.addAll(flattenConfigMap(Map<String, dynamic>.from(val), fullKey));
    } else {
      result[fullKey] = val;
    }
  }
  return result;
}

/// Recursively un-flattens a flat map with dot-separated keys into a nested map structure.
Map<String, dynamic> unflattenConfigMap(Map<String, dynamic> flat) {
  final result = <String, dynamic>{};

  // Pin schemaVersion to the very top of the generated JSON
  if (flat.containsKey(Config.schemaVersionKey)) {
    result[Config.schemaVersionKey] = flat[Config.schemaVersionKey];
  }

  for (final entry in flat.entries) {
    if (entry.key == Config.schemaVersionKey) continue;
    final key = entry.key;
    final value = entry.value;

    if (!key.contains('.')) {
      result[key] = value;
      continue;
    }

    final segments = key.split('.');
    Map<String, dynamic> current = result;
    for (int i = 0; i < segments.length - 1; i++) {
      final seg = segments[i];
      final existing = current[seg];
      if (existing is Map<String, dynamic>) {
        current = existing;
      } else if (existing is Map) {
        final converted = Map<String, dynamic>.from(existing);
        current[seg] = converted;
        current = converted;
      } else {
        final newMap = <String, dynamic>{};
        current[seg] = newMap;
        current = newMap;
      }
    }
    current[segments.last] = value;
  }
  return result;
}
