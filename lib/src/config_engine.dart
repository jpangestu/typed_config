import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'config_migration.dart';

const MapEquality<String, dynamic> _mapEquality = MapEquality<String, dynamic>();

/// Internal execution engine managing configuration cache, disk persistence,
/// debounce timers, file watchers, and change broadcasting.
@internal
final class ConfigEngine {
  static const bool _kDebugMode = !bool.fromEnvironment('dart.vm.product');

  final File? file;
  final Map<String, dynamic> cache;
  final StreamController<String> keyChanges;
  final void Function(String message)? onLog;
  final void Function(Object error, StackTrace stackTrace)? onError;

  Timer? _debounceTimer;
  Timer? _watcherDebounceTimer;
  Completer<void>? _currentWrite;
  Completer<void>? _nextWrite;
  StreamSubscription<FileSystemEvent>? _fileWatcherSubscription;
  int _writeNonce = 0;
  bool _isDisposed = false;

  bool get isDisposed => _isDisposed;

  ConfigEngine({
    this.file,
    Map<String, dynamic>? cache,
    StreamController<String>? keyChanges,
    this.onLog,
    this.onError,
  }) : cache = cache ?? <String, dynamic>{},
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

  bool containsKey(String key) => cache.containsKey(key);

  dynamic readRaw(String key) => cache[key];

  void writeRaw(String key, dynamic value) {
    if (_isDisposed) return;

    dynamic serialized = value;
    if (serialized is List) {
      serialized = List<dynamic>.unmodifiable(serialized);
    } else if (serialized is Map) {
      serialized = Map<String, dynamic>.unmodifiable(serialized);
    }

    if (cache.containsKey(key) && const DeepCollectionEquality().equals(cache[key], serialized)) {
      return;
    }

    cache[key] = serialized;
    _notifyKey(key);
    _scheduleSave();
  }

  void resetKey(String key) {
    if (_isDisposed || !cache.containsKey(key)) return;
    cache.remove(key);
    _notifyKey(key);
    _scheduleSave();
  }

  Future<void> resetAll() async {
    if (_isDisposed) return;
    cache.clear();
    _notifyKey('*');
    _scheduleSave();
    await flush();
  }

  Stream<String> watchKey(String key) {
    return keyChanges.stream.where((changedKey) => changedKey == key || changedKey == '*');
  }

  void _scheduleSave() {
    if (file == null || _isDisposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () => unawaited(flush()));
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
      try {
        final flatMap = Map<String, dynamic>.from(cache);
        final nestedMap = unflattenConfigMap(flatMap);
        final jsonString = JsonEncoder.withIndent('  ', (o) => o.toString()).convert(nestedMap);

        if (!targetFile.parent.existsSync()) {
          targetFile.parent.createSync(recursive: true);
        }

        final tempFile = File('${targetFile.path}.${pid}_${_writeNonce++}.tmp');
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

        log('Successfully written to disk.');
        completer.complete();
      } catch (e, s) {
        logError('Failed to write config to disk', e, s);
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

  void startWatcher() {
    final targetFile = file;
    if (targetFile == null || _isDisposed) return;
    if (!FileSystemEntity.isWatchSupported) return;

    try {
      _fileWatcherSubscription = targetFile.parent.watch().listen((event) {
        if (p.basename(event.path) == p.basename(targetFile.path) &&
            event.type != FileSystemEvent.delete) {
          _watcherDebounceTimer?.cancel();
          _watcherDebounceTimer = Timer(const Duration(milliseconds: 150), () async {
            await reloadFromDisk();
          });
        }
      });
    } catch (e) {
      log('Could not start file watcher: $e');
    }
  }

  Future<void> reloadFromDisk() async {
    final targetFile = file;
    if (targetFile == null || !targetFile.existsSync() || _isDisposed) return;

    try {
      final content = await targetFile.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Config JSON is not an object');
      }

      final flatDecoded = flattenConfigMap(decoded);
      if (_mapEquality.equals(cache, flatDecoded)) return;

      final changedKeys = <String>{};
      for (final entry in flatDecoded.entries) {
        if (!cache.containsKey(entry.key) ||
            !const DeepCollectionEquality().equals(cache[entry.key], entry.value)) {
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
      log('Reloaded from disk modification: ${changedKeys.join(", ")}');
    } catch (e, s) {
      logError('Failed to reload config from disk', e, s);
    }
  }

  static Future<void> quarantineFile(File file, void Function(String message)? log) async {
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

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;

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
          log('Synchronously written to disk on dispose.');
        } catch (e, s) {
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
