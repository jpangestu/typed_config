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

  final Set<String> _registeredKeys = <String>{};
  final Set<String> _registeredGroups = <String>{};

  Timer? _debounceTimer;
  Timer? _watcherDebounceTimer;
  Completer<void>? _currentWrite;
  Completer<void>? _nextWrite;
  StreamSubscription<FileSystemEvent>? _fileWatcherSubscription;
  DateTime? _ignoreWatcherUntil;
  int _writeNonce = 0;
  int _changeVersion = 0;
  int _disposedWriteVersion = -1;
  bool _isDisposed = false;
  bool isDirty = false;

  bool get isDisposed => _isDisposed;

  /// Monotonically increasing version counter used by [ConfigEntry] to memoize reads.
  int get changeVersion => _changeVersion;

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

  /// Registers a leaf configuration key and validates that no duplicate or
  /// conflicting group/ancestor key exists.
  void registerKey(String fullKey) {
    if (_registeredKeys.contains(fullKey)) {
      throw ArgumentError.value(
        fullKey,
        'key',
        'Duplicate configuration key "$fullKey" is already defined.',
      );
    }
    if (_registeredGroups.contains(fullKey)) {
      throw ArgumentError.value(
        fullKey,
        'key',
        'Configuration key "$fullKey" conflicts with an existing group prefix.',
      );
    }
    int dotIndex = fullKey.indexOf('.');
    while (dotIndex != -1) {
      final ancestor = fullKey.substring(0, dotIndex);
      if (_registeredKeys.contains(ancestor)) {
        throw ArgumentError.value(
          fullKey,
          'key',
          'Configuration key "$fullKey" conflicts with ancestor key "$ancestor".',
        );
      }
      dotIndex = fullKey.indexOf('.', dotIndex + 1);
    }
    final prefix = '$fullKey.';
    for (final existing in _registeredKeys) {
      if (existing.startsWith(prefix)) {
        throw ArgumentError.value(
          fullKey,
          'key',
          'Configuration key "$fullKey" conflicts with descendant key "$existing".',
        );
      }
    }
    _registeredKeys.add(fullKey);
  }

  /// Registers a group namespace prefix and validates that it does not collide
  /// with an already registered leaf key.
  void registerGroup(String prefix) {
    if (_registeredKeys.contains(prefix)) {
      throw ArgumentError.value(
        prefix,
        'name',
        'Group prefix "$prefix" conflicts with an existing configuration key.',
      );
    }
    int dotIndex = prefix.indexOf('.');
    while (dotIndex != -1) {
      final ancestor = prefix.substring(0, dotIndex);
      if (_registeredKeys.contains(ancestor)) {
        throw ArgumentError.value(
          prefix,
          'name',
          'Group prefix "$prefix" conflicts with ancestor configuration key "$ancestor".',
        );
      }
      dotIndex = prefix.indexOf('.', dotIndex + 1);
    }
    _registeredGroups.add(prefix);
  }

  void log(String message) {
    if (onLog != null) {
      onLog!(message);
    } else if (_kDebugMode) {
      print('[Config] $message');
    }
  }

  void logError(String message, Object error, StackTrace stackTrace) {
    if (onError != null) {
      onLog?.call('[ERROR] $message: $error');
      onError!(error, stackTrace);
    } else if (_kDebugMode) {
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

    final dynamic serialized = freezeConfigValue(value);

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

  void resetKey(String key, {bool scheduleSave = true}) {
    if (_isDisposed) return;
    bool removed = cache.remove(key) != null;
    if (removeKeyDescendants(cache, key)) {
      removed = true;
    }
    if (!removed) return;

    _changeVersion++;
    isDirty = true;
    _notifyKey(key);
    if (scheduleSave) {
      _scheduleSave();
    }
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
    await flush();
  }

  Stream<String> watchKey(String key) {
    if (key == '*') return keyChanges.stream;
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
      () => unawaited(flush().catchError((_) {})),
    );
  }

  Future<void> _deleteTempQuietly(File? tempFile) async {
    if (tempFile == null) return;
    try {
      if (await tempFile.exists()) await tempFile.delete();
    } catch (_) {}
  }

  Future<void> flush() {
    final targetFile = file;
    if (targetFile == null || _isDisposed) return Future.value();

    _debounceTimer?.cancel();

    if (_currentWrite != null) {
      if (!isDirty) return _currentWrite!.future;
      _nextWrite ??= Completer<void>();
      return _nextWrite!.future;
    }

    if (!isDirty) return Future.value();

    final completer = Completer<void>();
    _currentWrite = completer;

    () async {
      File? tempFile;
      try {
        while (!_isDisposed && isDirty) {
          _debounceTimer?.cancel();
          final writeVersion = _changeVersion;
          final flatMap = Map<String, dynamic>.from(cache);
          final nestedMap = unflattenConfigMap(flatMap);
          final jsonString = const JsonEncoder.withIndent('  ').convert(nestedMap);

          if (!await targetFile.parent.exists()) {
            await targetFile.parent.create(recursive: true);
          }

          if (_isDisposed) {
            completer.complete();
            return;
          }

          tempFile = File('${targetFile.path}.${pid}_${_writeNonce++}.tmp');
          _ignoreWatcherUntil = DateTime.now().add(const Duration(seconds: 2));
          await tempFile.writeAsString(jsonString, flush: true);

          // If dispose() ran or a newer write occurred while writing tempFile, discard
          // tempFile and retry with the latest snapshot so we never overwrite newer state.
          if (_isDisposed || _changeVersion != writeVersion) {
            await _deleteTempQuietly(tempFile);
            tempFile = null;
            if (_isDisposed) {
              completer.complete();
              return;
            }
            continue;
          }

          try {
            await tempFile.rename(targetFile.path);
          } on FileSystemException {
            if (_isDisposed || _changeVersion != writeVersion) {
              await _deleteTempQuietly(tempFile);
              tempFile = null;
              if (_isDisposed) {
                completer.complete();
                return;
              }
              continue;
            }
            // Fallback for Windows lock contention
            await tempFile.copy(targetFile.path);
            await _deleteTempQuietly(tempFile);
          }
          tempFile = null;

          // If dispose() ran concurrently while the async rename/copy was in-flight in the OS
          // thread pool and wrote a newer version, re-apply the synchronous dispose write.
          if (_isDisposed) {
            if (_disposedWriteVersion > writeVersion) {
              _writeSync(targetFile);
            }
            completer.complete();
            return;
          }

          _ignoreWatcherUntil = DateTime.now().add(
            const Duration(milliseconds: 250),
          );
          if (_changeVersion == writeVersion) {
            isDirty = false;
          }
          log('Successfully written to disk.');
          break;
        }
        if (!completer.isCompleted) {
          completer.complete();
        }
      } catch (e, s) {
        await _deleteTempQuietly(tempFile);
        logError('Failed to write config to disk', e, s);
        if (!completer.isCompleted) {
          completer.completeError(e, s);
        }
      } finally {
        _currentWrite = null;
        if (_nextWrite != null) {
          final next = _nextWrite!;
          _nextWrite = null;
          if (_isDisposed || !isDirty) {
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

  static bool _matchesTargetFile(FileSystemEvent event, String targetName) {
    if (p.basename(event.path) == targetName && event.type != FileSystemEvent.delete) {
      return true;
    }
    if (event is FileSystemMoveEvent &&
        event.destination != null &&
        p.basename(event.destination!) == targetName) {
      return true;
    }
    return false;
  }

  void startWatcher() {
    final targetFile = file;
    if (targetFile == null || _isDisposed) return;
    if (!FileSystemEntity.isWatchSupported) return;

    _fileWatcherSubscription?.cancel();
    final targetName = p.basename(targetFile.path);

    try {
      _fileWatcherSubscription = targetFile.parent.watch().listen(
        (event) {
          if (_matchesTargetFile(event, targetName)) {
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
        },
        onError: (Object e, StackTrace s) {
          log('File watcher error: $e');
        },
      );
    } catch (e) {
      log('Could not start file watcher: $e');
    }
  }

  Future<void> reloadFromDisk() async {
    final targetFile = file;
    if (targetFile == null || _isDisposed || !await targetFile.exists()) return;

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

    if (!await configFile.exists()) {
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
          onLog?.call('[ERROR] Failed to load existing config. Resetting to defaults.: $e');
          onError(e, s);
        } else if (_kDebugMode) {
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
    if (!await file.exists()) return;
    try {
      var corruptFile = File('${file.path}.$suffix');
      if (await corruptFile.exists()) {
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

  void _writeSync(File targetFile) {
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
      _disposedWriteVersion = _changeVersion;
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

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;

    final shouldWrite = isDirty || (_debounceTimer?.isActive ?? false);
    _debounceTimer?.cancel();

    if (shouldWrite) {
      final targetFile = file;
      if (targetFile != null) {
        _writeSync(targetFile);
      }
    }
    _watcherDebounceTimer?.cancel();
    _fileWatcherSubscription?.cancel();
    keyChanges.close();
  }

  Map<String, dynamic> toFlatJson() => Map<String, dynamic>.unmodifiable(cache);

  Map<String, dynamic> toJson() => unflattenConfigMap(cache);
}
