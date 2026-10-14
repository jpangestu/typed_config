import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'config_migration.dart';

const DeepCollectionEquality _deepEquality = DeepCollectionEquality();
const MapEquality<String, dynamic> _mapEquality = MapEquality<String, dynamic>(
  values: _deepEquality,
);

/// Internal execution engine managing configuration cache, disk persistence,
/// debounce timers, file watchers, and change broadcasting.
@internal
final class ConfigEngine {
  static const bool _kDebugMode = !bool.fromEnvironment('dart.vm.product');

  final File? file;
  final int schemaVersion;
  final Map<int, ConfigMigrator>? migrations;
  final Map<String, dynamic> cache;
  final StreamController<String> keyChanges;
  final void Function(String message)? onLog;
  final void Function(Object error, StackTrace stackTrace)? onError;

  Timer? _debounceTimer;
  Timer? _watcherDebounceTimer;
  Completer<void>? _currentWrite;
  Completer<void>? _nextWrite;
  StreamSubscription<FileSystemEvent>? _fileWatcherSubscription;
  DateTime? _ignoreWatcherUntil;
  int _writeNonce = 0;
  int _changeVersion = 0;
  bool _isDisposed = false;
  bool isDirty = false;

  bool get isDisposed => _isDisposed;

  ConfigEngine({
    this.file,
    this.schemaVersion = 1,
    this.migrations,
    Map<String, dynamic>? cache,
    StreamController<String>? keyChanges,
    this.isDirty = false,
    this.onLog,
    this.onError,
  })  : cache = cache ?? <String, dynamic>{},
        keyChanges = keyChanges ?? StreamController<String>.broadcast();

  void log(String message) {
    if (onLog != null) {
      onLog!(message);
    } else if (_kDebugMode) {
      print('[Config] $message');
    }
  }

  void logError(String message, Object error, StackTrace stackTrace) {
    if (onError != null) {
      onError!(error, stackTrace);
    } else {
      print('[Config ERROR] $message: $error');
    }
  }

  void _notifyKey(String key) {
    if (!_isDisposed && !keyChanges.isClosed) {
      keyChanges.add(key);
    }
  }

  bool containsKey(String key) {
    if (cache.containsKey(key)) return true;
    final prefix = '$key.';
    return cache.keys.any((k) => k.startsWith(prefix));
  }

  dynamic readRaw(String key) {
    // Fast O(1) path for all primitives, enums, lists, explicit nulls, and empty maps
    if (cache.containsKey(key)) return cache[key];

    // Reconstruct nested map if 'key.*' entries exist
    final prefix = '$key.';
    Map<String, dynamic>? subFlat;
    for (final entry in cache.entries) {
      if (entry.key.startsWith(prefix)) {
        (subFlat ??= <String, dynamic>{})[entry.key.substring(prefix.length)] = entry.value;
      }
    }
    if (subFlat != null) {
      return unflattenConfigMap(subFlat);
    }
    return null;
  }

  void writeRaw(String key, dynamic value) {
    if (_isDisposed) return;

    final prefix = '$key.';

    if (value is Map) {
      final incomingFlat = value.isEmpty
          ? <String, dynamic>{key: const <String, dynamic>{}}
          : flattenConfigMap(value, key, true);

      // Check if the current state for this key/prefix already matches incomingFlat
      final currentFlat = <String, dynamic>{
        if (cache.containsKey(key)) key: cache[key],
        for (final e in cache.entries)
          if (e.key.startsWith(prefix)) e.key: e.value,
      };

      if (_mapEquality.equals(currentFlat, incomingFlat)) return;

      removeKeyAncestors(cache, key);
      cache.remove(key);
      removeKeyDescendants(cache, key);
      cache.addAll(incomingFlat);

      _changeVersion++;
      isDirty = true;
      _notifyKey(key);
      _scheduleSave();
      return;
    }

    dynamic serialized = value;
    if (serialized is List) {
      serialized = List<dynamic>.unmodifiable(serialized);
    }

    if (cache.containsKey(key) && _deepEquality.equals(cache[key], serialized)) {
      return;
    }

    removeKeyAncestors(cache, key);
    removeKeyDescendants(cache, key);
    cache[key] = serialized;
    _changeVersion++;
    isDirty = true;
    _notifyKey(key);
    _scheduleSave();
  }

  void resetKey(String key) {
    if (_isDisposed) return;
    bool removed = cache.remove(key) != null;
    if (removeKeyDescendants(cache, key)) {
      removed = true;
    }
    if (!removed) return;

    _changeVersion++;
    isDirty = true;
    _notifyKey(key);
    _scheduleSave();
  }

  Future<void> resetAll() async {
    if (_isDisposed) return;
    final keepVersion = file != null || cache.containsKey(schemaVersionKey);
    cache.clear();
    if (keepVersion) {
      cache[schemaVersionKey] = schemaVersion;
    }
    _changeVersion++;
    isDirty = true;
    _notifyKey('*');
    _scheduleSave();
    await flush();
  }

  Stream<String> watchKey(String key) {
    final prefix = '$key.';
    return keyChanges.stream.where(
      (changedKey) =>
          changedKey == key ||
          changedKey == '*' ||
          changedKey.startsWith(prefix) ||
          key.startsWith('$changedKey.'),
    );
  }

  void _scheduleSave() {
    if (file == null || _isDisposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(flush()),
    );
  }

  Future<void> flush() {
    final targetFile = file;
    if (targetFile == null || _isDisposed) return Future.value();

    _debounceTimer?.cancel();

    if (_currentWrite != null) {
      _nextWrite ??= Completer<void>();
      return _nextWrite!.future;
    }

    final completer = Completer<void>();
    _currentWrite = completer;

    () async {
      final writeVersion = _changeVersion;
      File? tempFile;
      try {
        final flatMap = Map<String, dynamic>.from(cache);
        final nestedMap = unflattenConfigMap(flatMap);
        final jsonString = const JsonEncoder.withIndent('  ').convert(nestedMap);

        if (!targetFile.parent.existsSync()) {
          targetFile.parent.createSync(recursive: true);
        }

        tempFile = File('${targetFile.path}.${pid}_${_writeNonce++}.tmp');
        _ignoreWatcherUntil = DateTime.now().add(const Duration(seconds: 2));
        await tempFile.writeAsString(jsonString, flush: true);

        if (_isDisposed) {
          try {
            if (tempFile.existsSync()) await tempFile.delete();
          } catch (_) {}
          completer.complete();
          return;
        }

        try {
          await tempFile.rename(targetFile.path);
        } on FileSystemException {
          if (_isDisposed) {
            try {
              if (tempFile.existsSync()) await tempFile.delete();
            } catch (_) {}
            completer.complete();
            return;
          }
          // Fallback for Windows lock contention
          await tempFile.copy(targetFile.path);
          try {
            await tempFile.delete();
          } catch (_) {}
        }

        _ignoreWatcherUntil = DateTime.now().add(
          const Duration(milliseconds: 250),
        );
        if (_changeVersion == writeVersion) {
          isDirty = false;
        }
        log('Successfully written to disk.');
        completer.complete();
      } catch (e, s) {
        if (tempFile != null) {
          try {
            if (tempFile.existsSync()) await tempFile.delete();
          } catch (_) {}
        }
        logError('Failed to write config to disk', e, s);
        completer.completeError(e, s);
      } finally {
        _currentWrite = null;
        if (_nextWrite != null) {
          final next = _nextWrite!;
          _nextWrite = null;
          if (_isDisposed) {
            next.complete();
          } else {
            flush().then(next.complete, onError: next.completeError);
          }
        }
      }
    }();

    return completer.future;
  }

  bool get _shouldIgnoreWatcherEvent {
    if (_isDisposed || _currentWrite != null || isDirty) return true;
    if (_debounceTimer?.isActive ?? false) return true;
    final ignoreUntil = _ignoreWatcherUntil;
    if (ignoreUntil != null && DateTime.now().isBefore(ignoreUntil)) {
      return true;
    }
    return false;
  }

  void startWatcher() {
    final targetFile = file;
    if (targetFile == null || _isDisposed) return;
    if (!FileSystemEntity.isWatchSupported) return;

    _fileWatcherSubscription?.cancel();

    try {
      _fileWatcherSubscription = targetFile.parent.watch().listen((event) {
        if (p.basename(event.path) == p.basename(targetFile.path) &&
            event.type != FileSystemEvent.delete) {
          if (_shouldIgnoreWatcherEvent) return;
          _watcherDebounceTimer?.cancel();
          _watcherDebounceTimer = Timer(
            const Duration(milliseconds: 150),
            () async {
              if (_shouldIgnoreWatcherEvent) return;
              await reloadFromDisk();
            },
          );
        }
      });
    } catch (e) {
      log('Could not start file watcher: $e');
    }
  }

  Future<void> reloadFromDisk() async {
    final targetFile = file;
    if (targetFile == null || !targetFile.existsSync() || _isDisposed) return;

    final startChangeVersion = _changeVersion;

    try {
      final content = await targetFile.readAsString();

      // Abort if state was modified in memory, a write started, or engine was disposed while reading
      if (_isDisposed || isDirty || _changeVersion != startChangeVersion || _currentWrite != null) {
        return;
      }

      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Config JSON is not an object');
      }

      final flatDecoded = flattenConfigMap(decoded);
      final migrationResult = migrateConfigData(
        data: flatDecoded,
        targetVersion: schemaVersion,
        migrations: migrations,
        onLog: log,
      );
      final newCache = migrationResult.data;

      if (_mapEquality.equals(cache, newCache)) {
        if (migrationResult.didMigrate) {
          isDirty = true;
          _scheduleSave();
        }
        return;
      }

      final changedKeys = <String>{};
      for (final entry in newCache.entries) {
        if (!cache.containsKey(entry.key) || !_deepEquality.equals(cache[entry.key], entry.value)) {
          changedKeys.add(entry.key);
        }
      }
      for (final key in cache.keys) {
        if (!newCache.containsKey(key)) {
          changedKeys.add(key);
        }
      }

      cache.clear();
      cache.addAll(newCache);
      _changeVersion++;

      if (migrationResult.didMigrate) {
        isDirty = true;
        _scheduleSave();
      } else {
        _debounceTimer?.cancel();
        isDirty = false;
      }

      for (final key in changedKeys) {
        _notifyKey(key);
      }
      log('Reloaded from disk modification: ${changedKeys.join(", ")}');
    } catch (e, s) {
      logError('Failed to reload config from disk', e, s);
    }
  }

  /// Asynchronously loads a [ConfigEngine] from disk, running schema migrations or quarantining corrupt files.
  static Future<ConfigEngine> load(
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

    final logger = onLog ?? (_kDebugMode ? (String msg) => print('[Config] $msg') : null);

    Map<String, dynamic> cache;
    bool isDirty = false;

    if (!configFile.existsSync()) {
      cache = <String, dynamic>{schemaVersionKey: schemaVersion};
      isDirty = true;
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
        );

        cache = migrationResult.data;
        if (migrationResult.didMigrate) {
          isDirty = true;
          logger?.call(
            'Migrated config schema from v${migrationResult.fromVersion} to v${migrationResult.toVersion}.',
          );
        }
      } catch (e, s) {
        final suffix = e is ConfigMigrationException ? 'v${e.fromVersion}.corrupt' : 'corrupt';
        await quarantineFile(configFile, logger, suffix: suffix);
        cache = <String, dynamic>{schemaVersionKey: schemaVersion};
        isDirty = true;
        if (onError != null) {
          onError(e, s);
        } else {
          print(
            '[Config ERROR] Failed to load existing config. Resetting to defaults.: $e',
          );
        }
      }
    }

    return ConfigEngine(
      file: configFile,
      schemaVersion: schemaVersion,
      migrations: migrations,
      cache: cache,
      isDirty: isDirty,
      onLog: onLog,
      onError: onError,
    );
  }

  /// Instantiates an in-memory [ConfigEngine] without file persistence.
  static ConfigEngine inMemory([Map<String, dynamic>? initialCache]) {
    return ConfigEngine(
      cache: initialCache != null ? flattenConfigMap(initialCache) : <String, dynamic>{},
    );
  }

  static Future<void> quarantineFile(
    File file,
    void Function(String message)? log, {
    String suffix = 'corrupt',
  }) async {
    if (!file.existsSync()) return;
    try {
      var corruptFile = File('${file.path}.$suffix');
      if (corruptFile.existsSync()) {
        // Preserve previous quarantined file if one already exists
        corruptFile = File(
          '${file.path}.${DateTime.now().millisecondsSinceEpoch}.$suffix',
        );
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

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;

    final shouldWrite = isDirty || (_debounceTimer?.isActive ?? false);
    _debounceTimer?.cancel();

    if (shouldWrite) {
      final targetFile = file;
      if (targetFile != null) {
        File? tempFile;
        try {
          if (!targetFile.parent.existsSync()) {
            targetFile.parent.createSync(recursive: true);
          }
          final jsonStr = const JsonEncoder.withIndent('  ').convert(unflattenConfigMap(cache));

          tempFile = File(
            '${targetFile.path}.${pid}_${_writeNonce++}.tmp',
          );
          tempFile.writeAsStringSync(jsonStr, flush: true);

          try {
            tempFile.renameSync(targetFile.path);
          } on FileSystemException {
            tempFile.copySync(targetFile.path);
            try {
              tempFile.deleteSync();
            } catch (_) {}
          }
          isDirty = false;
          log('Synchronously written to disk on dispose.');
        } catch (e, s) {
          if (tempFile != null) {
            try {
              if (tempFile.existsSync()) tempFile.deleteSync();
            } catch (_) {}
          }
          logError('Failed to write config on dispose', e, s);
        }
      }
    }
    _watcherDebounceTimer?.cancel();
    _fileWatcherSubscription?.cancel();
    keyChanges.close();
  }

  Map<String, dynamic> toFlatJson() => Map<String, dynamic>.unmodifiable(cache);

  Map<String, dynamic> toJson() => unflattenConfigMap(cache);
}
