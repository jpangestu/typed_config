import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

import 'config_entry.dart';

/// Function signature for migrating raw configuration JSON maps between schema versions.
typedef ConfigMigrator = void Function(Map<String, dynamic> raw);

const MapEquality<String, dynamic> _mapEquality =
    MapEquality<String, dynamic>();

/// Recursively flattens a nested map into a flat map with dot-separated keys.
Map<String, dynamic> flattenConfigMap(
  Map<String, dynamic> nested, [
  String prefix = '',
]) {
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

/// Central application configuration engine managing in-memory cache,
/// debounced atomic disk writes, and cross-platform file synchronization.
///
/// Reads are synchronous via [get]. Updates via [set] modify memory immediately
/// and schedule a debounced save to disk to prevent I/O thrashing.
class Config([
  final File? _file,
  final Map<String, dynamic>? initialCache,
  final void Function(String message)? onLog,
  final void Function(Object error, StackTrace stackTrace)? onError,
]) {
  /// Key used in JSON storage to track the current configuration schema version.
  static const String schemaVersionKey = 'schemaVersion';

  static const bool _kDebugMode = !bool.fromEnvironment('dart.vm.product');

  final Map<String, dynamic> _cache = initialCache != null
      ? flattenConfigMap(initialCache)
      : <String, dynamic>{};
  final StreamController<String> _keyChanges =
      StreamController<String>.broadcast();
  final void Function(String message)? _onLog = onLog;
  final void Function(Object error, StackTrace stackTrace)? _onError = onError;

  Timer? _debounceTimer;
  Timer? _watcherDebounceTimer;
  Completer<void>? _currentWrite;
  Completer<void>? _nextWrite;
  StreamSubscription<FileSystemEvent>? _fileWatcherSubscription;
  DateTime? _lastInternalWriteTime;

  /// Creates an in-memory configuration instance for synchronous reads.
  new inMemory([Map<String, dynamic>? initialCache]) : this(null, initialCache);

  /// Emits debug information through [_onLog] or [print].
  void _log(String message) {
    if (_onLog != null) {
      _onLog(message);
    } else if (_kDebugMode) {
      print('[Config] $message');
    }
  }

  /// Emits error details through [_onError] or [print].
  void _logError(String message, Object error, StackTrace stackTrace) {
    if (_onError != null) {
      _onError(error, stackTrace);
    } else {
      print('[Config ERROR] $message: $error');
    }
  }

  /// Broadcasts a change event for [key] if the stream controller is not closed.
  void _notifyKey(String key) {
    if (!_keyChanges.isClosed) {
      _keyChanges.add(key);
    }
  }

  // ========================================================================================================
  // Core Engine Operations
  // ========================================================================================================

  /// Check whether [entry] has an explicitly stored value in the cache.
  bool contains<T>(ConfigEntry<T> entry) => _cache.containsKey(entry.key);

  /// Synchronously returns the typed value of [entry] from memory.
  ///
  /// Falls back to [ConfigEntry.defaultValue] if the entry is not in cache.
  T get<T>(ConfigEntry<T> entry) {
    if (!_cache.containsKey(entry.key)) {
      return entry.defaultValue;
    }
    return entry.parse(_cache[entry.key]);
  }

  /// Updates [entry] to [value] in memory and schedules saving to disk.
  ///
  /// Collections are defensively wrapped in unmodifiable views. Emits an event
  /// to [watch] listeners immediately; disk I/O does not block this call.
  void set<T>(ConfigEntry<T> entry, T value) {
    dynamic serialized = entry.serialize(value);
    if (serialized is List) {
      serialized = List<dynamic>.unmodifiable(serialized);
    } else if (serialized is Map) {
      serialized = Map<String, dynamic>.unmodifiable(serialized);
    }
    if (_cache.containsKey(entry.key) && _cache[entry.key] == serialized) {
      return;
    }
    _cache[entry.key] = serialized;
    _notifyKey(entry.key);
    _scheduleSave();
  }

  /// Resets [entry] in memory back to its default value and schedules saving to disk.
  ///
  /// Emits a change event and schedules saving to disk.
  void reset<T>(ConfigEntry<T> entry) {
    if (!_cache.containsKey(entry.key)) return;
    _cache.remove(entry.key);
    _notifyKey(entry.key);
    _scheduleSave();
  }

  /// Clears all configuration overrides, reverts all entries to defaults, and flushes to disk immediately.
  ///
  /// Emits a wildcard change notifying all active [watch] listeners.
  Future<void> resetAll() async {
    _cache.clear();
    _notifyKey('*');
    _scheduleSave();
    await flush();
  }

  /// Returns a broadcast stream emitting the latest value whenever [entry] changes.
  ///
  /// Filters out changes to unrelated entries. Also fires when [resetAll]
  /// or external disk reloads trigger.
  Stream<T> watch<T>(ConfigEntry<T> entry) {
    return _keyChanges.stream
        .where((changedKey) => changedKey == entry.key || changedKey == '*')
        .map((_) => get(entry));
  }

  // ========================================================================================================
  // Disk Writes & External Reload
  // ========================================================================================================

  /// Schedules saving to disk after 300ms of inactivity.
  void _scheduleSave() {
    if (_file == null) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(flush()),
    );
  }

  /// Immediately writes in-memory configuration changes to disk without waiting for the debounce timer.
  ///
  /// Cancels any scheduled debounce timer and writes the latest cache snapshot to the underlying file.
  ///
  /// Coalesces overlapping calls so concurrent requests share a single serialized
  /// write execution rather than colliding on disk. The returned [Future] completes
  /// only after the latest in-memory state has been physically written.
  Future<void> flush() {
    final file = _file;
    if (file == null) return Future.value();

    _debounceTimer?.cancel();

    if (_currentWrite != null) {
      _nextWrite ??= Completer<void>();
      return _nextWrite!.future;
    }

    final completer = Completer<void>();
    _currentWrite = completer;

    () async {
      try {
        final flatMap = Map<String, dynamic>.from(_cache);
        final nestedMap = unflattenConfigMap(flatMap);
        final jsonString = JsonEncoder.withIndent(
          '  ',
          (o) => o.toString(),
        ).convert(nestedMap);

        if (!file.parent.existsSync()) {
          file.parent.createSync(recursive: true);
        }

        final tempFile = File('${file.path}.$pid.tmp');
        await tempFile.writeAsString(jsonString, flush: true);

        try {
          await tempFile.rename(file.path);
        } on FileSystemException {
          // Fallback for Windows lock contention
          await tempFile.copy(file.path);
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

  /// Watches the configuration file for external changes.
  ///
  /// Disabled on mobile (Android/iOS) to prevent battery drain and sandbox violations.
  /// Ignores internal write echoes and debounces bursts by 150ms.
  void _startWatcher() {
    final file = _file;
    if (file == null) return;
    if (!FileSystemEntity.isWatchSupported) return;
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;

    try {
      _fileWatcherSubscription = file.parent.watch().listen((event) {
        if (p.basename(event.path) == p.basename(file.path) &&
            event.type != FileSystemEvent.delete) {
          final lastWrite = _lastInternalWriteTime;
          if (lastWrite != null &&
              DateTime.now().difference(lastWrite).inMilliseconds < 1000) {
            // Ignore internal write echo
            return;
          }
          _watcherDebounceTimer?.cancel();
          _watcherDebounceTimer = Timer(const Duration(milliseconds: 150), () async {
            if (!file.existsSync()) return;
            try {
              final content = await file.readAsString();
              final decoded = jsonDecode(content);
              if (decoded is Map<String, dynamic>) {
                final flatDecoded = flattenConfigMap(decoded);
                if (_mapEquality.equals(_cache, flatDecoded)) return;
                final changedKeys = <String>{};
                for (final entry in flatDecoded.entries) {
                  if (_cache[entry.key] != entry.value) {
                    changedKeys.add(entry.key);
                  }
                }
                for (final key in _cache.keys) {
                  if (!flatDecoded.containsKey(key)) {
                    changedKeys.add(key);
                  }
                }
                _cache.clear();
                _cache.addAll(flatDecoded);
                for (final k in changedKeys) {
                  _notifyKey(k);
                }
                _log(
                  'Reloaded from disk modification: ${changedKeys.join(", ")}',
                );
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
    final file = _file;
    if (file == null || !file.existsSync()) return;

    try {
      final content = await file.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Config JSON is not an object');
      }

      final flatDecoded = flattenConfigMap(decoded);
      final changedKeys = <String>{};

      for (final entry in flatDecoded.entries) {
        if (!_cache.containsKey(entry.key) ||
            _cache[entry.key] != entry.value) {
          changedKeys.add(entry.key);
        }
      }
      for (final key in _cache.keys) {
        if (!flatDecoded.containsKey(key)) {
          changedKeys.add(key);
        }
      }

      _cache.clear();
      _cache.addAll(flatDecoded);

      for (final key in changedKeys) {
        _notifyKey(key);
      }
      _log('Reloaded from disk.');
    } catch (e, s) {
      _logError('Failed to reload config from disk', e, s);
    }
  }

  /// Safely renames or copies a corrupted file to [file.path].corrupt.
  static Future<void> _quarantineFile(
    File file,
    void Function(String message)? log,
  ) async {
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

  /// Loads configuration from [configFile], creating default storage if missing.
  ///
  /// Automatically applies [migrations] if [schemaVersion] is greater than the
  /// stored file version. If the file contains invalid JSON or migrations fail,
  /// the damaged file is safely quarantined to `${configFile.path}.corrupt` before
  /// initializing clean defaults.
  ///
  /// Automatically starts external file watching on desktop platforms.
  static Future<Config> load(
    File configFile, {
    int schemaVersion = 1,
    Map<int, ConfigMigrator>? migrations,
    void Function(String message)? onLog,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) async {
    final logger =
        onLog ?? (_kDebugMode ? (msg) => print('[Config] $msg') : null);

    if (!configFile.existsSync()) {
      final initialData = <String, dynamic>{schemaVersionKey: schemaVersion};
      final config = Config(configFile, initialData, onLog, onError);
      await config.flush();
      config._startWatcher();
      return config;
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
              migrator(flatDecoded);
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

      final config = Config(configFile, flatDecoded, onLog, onError);
      if (needsFlush) {
        await config.flush();
        config._log(
          'Migrated config schema from v$fileVersion to v$schemaVersion.',
        );
      }
      config._startWatcher();
      return config;
    } catch (e, s) {
      await _quarantineFile(configFile, logger);
      final initialData = <String, dynamic>{schemaVersionKey: schemaVersion};
      final config = Config(configFile, initialData, onLog, onError);
      config._logError(
        'Failed to load existing config. Resetting to defaults.',
        e,
        s,
      );
      await config.flush();
      config._startWatcher();
      return config;
    }
  }

  /// Releases active timers, file watchers, and streams.
  ///
  /// Synchronously saves any pending dirty changes to disk before closing to
  /// prevent data loss on fast application exit.
  void dispose() {
    if (_debounceTimer?.isActive ?? false) {
      _debounceTimer?.cancel();
      final file = _file;
      if (file != null) {
        try {
          if (!file.parent.existsSync()) {
            file.parent.createSync(recursive: true);
          }
          final jsonStr = JsonEncoder.withIndent(
            '  ',
            (o) => o.toString(),
          ).convert(unflattenConfigMap(_cache));
          file.writeAsStringSync(jsonStr, flush: true);
          _log('Synchronously written to disk on dispose.');
        } catch (e, s) {
          _logError('Failed to write config on dispose', e, s);
        }
      }
    }
    _watcherDebounceTimer?.cancel();
    _fileWatcherSubscription?.cancel();
    _keyChanges.close();
  }

  /// Returns an unmodifiable snapshot map of all configuration entries in memory.
  Map<String, dynamic> toFlatJson() =>
      Map<String, dynamic>.unmodifiable(_cache);

  /// Returns the nested unflattened JSON map as it would appear on disk.
  Map<String, dynamic> toJson() => unflattenConfigMap(_cache);
}
