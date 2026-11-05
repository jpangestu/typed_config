import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

final class ConfigEngine {
  final File? _storedConfigFile;
  final Map<String, dynamic> _inMemoryCache;
  final bool saveDefaultValue;
  final Duration debounceDuration;
  final void Function(String message)? onLog;
  final void Function(Object error, StackTrace stackTrace)? onError;

  ConfigEngine({
    File? storedConfigFile,
    required Map<String, dynamic> inMemoryCache,
    this.saveDefaultValue = defaultSaveDefaultValue,
    this.debounceDuration = defaultDebounceDuration,
    this.onLog,
    this.onError,
  })  : _storedConfigFile = storedConfigFile,
        _inMemoryCache = inMemoryCache;

  static const defaultSaveDefaultValue = false;
  static const defaultDebounceDuration = Duration(milliseconds: 300);

  final Map<String, dynamic> _allEntryDefaultCache = {};
  Timer? _debouncedTimer;
  final StreamController<List<String>> _changeController = StreamController.broadcast();
  bool _isCacheNeedsSave = false;

  bool _isFlushing = false;
  String? _lastFlushedContent;

  StreamSubscription<FileSystemEvent>? _configFileWatcherSub;
  Timer? _configFileReloadTimer;

  /// Whether the configuration file is actively being watched for external changes.
  bool get isWatchingConfigFile => _configFileWatcherSub != null;

  // Add typed_config for each log
  void _log(String message) {
    onLog?.call('[typed_config] $message');
  }

  /// Traverses [inMemoryCache] to read the value of leaf key in keyPath.
  ///
  /// [keyPath] is the sequence of nested map keys leading to the target value
  /// (e.g. `['audio', 'volume']` reaches `json['audio']['volume']`).
  dynamic read(List<String> keyPath) {
    dynamic current = _inMemoryCache;

    for (final segment in keyPath) {
      if (current is! Map) return null;
      current = current[segment];
    }
    return current;
  }

  void write(List<String> keyPath, dynamic value) {
    if (keyPath.isEmpty) return;

    Map<String, dynamic> currentCache = _inMemoryCache;

    // Create new map if not exist
    for (int i = 0; i < keyPath.length - 1; i++) {
      final segmentKey = keyPath[i];
      final next = currentCache[segmentKey];

      if (next is Map<String, dynamic>) {
        currentCache = next;
      } else if (next is Map) {
        final converted = Map<String, dynamic>.from(next);
        currentCache[segmentKey] = converted;
        currentCache = converted;
      } else {
        // If missing or not a map, create a fresh map.
        final newMap = <String, dynamic>{};
        currentCache[segmentKey] = newMap;
        currentCache = newMap;
      }
    }

    // Return if new value == old value
    if (currentCache.containsKey(keyPath.last) &&
        const DeepCollectionEquality().equals(currentCache[keyPath.last], value)) {
      return;
    }

    currentCache[keyPath.last] = value;
    _isCacheNeedsSave = true;
    if (_changeController.isClosed == false) {
      _changeController.add(keyPath);
    }
    _debouncedSave();
  }

  /// Ensures that [key] is the very first entry in the root JSON map with [value].
  void writeFirst(String key, dynamic value) {
    // If it's already the first key and has the exact value, nothing to do
    if (_inMemoryCache.keys.isNotEmpty && _inMemoryCache.keys.first == key) {
      if (_inMemoryCache[key] == value) return;
      _inMemoryCache[key] = value;
    } else {
      // Rebuild the map with [key] as the first entry
      final remaining = Map<String, dynamic>.from(_inMemoryCache)..remove(key);
      _inMemoryCache.clear();
      _inMemoryCache[key] = value;
      _inMemoryCache.addAll(remaining);
    }

    _isCacheNeedsSave = true;
    if (!_changeController.isClosed) {
      _changeController.add([key]);
    }
    _debouncedSave();
  }

  /// Direct reference to the raw in-memory configuration map.
  Map<String, dynamic> get raw => _inMemoryCache;

  /// Write default value for [keyPath] if [saveDefaultValue] is true cache it to [allEntriesDefaultValue].
  void writeDefault(List<String> keyPath, dynamic encodedDefault) {
    if (!saveDefaultValue || keyPath.isEmpty) return;

    Map<String, dynamic> currentCache = _allEntryDefaultCache;

    for (int i = 0; i < keyPath.length - 1; i++) {
      final segmentKey = keyPath[i];
      final next = currentCache[segmentKey];
      if (next is Map<String, dynamic>) {
        currentCache = next;
      } else {
        final newMap = <String, dynamic>{};
        currentCache[segmentKey] = newMap;
        currentCache = newMap;
      }
    }
    currentCache[keyPath.last] = encodedDefault;

    if (saveDefaultValue && !containsKey(keyPath)) {
      write(keyPath, encodedDefault);
    }
  }

  void remove(List<String> keyPath) {
    if (keyPath.isEmpty) return;

    dynamic currentCache = _inMemoryCache;
    // Traverse to the parent map of the leaf key in key path
    for (int i = 0; i < keyPath.length - 1; i++) {
      if (currentCache is! Map) return;
      currentCache = currentCache[keyPath[i]];
    }

    if (currentCache is Map && currentCache.containsKey(keyPath.last)) {
      currentCache.remove(keyPath.last);
      _isCacheNeedsSave = true;
      if (_changeController.isClosed == false) {
        _changeController.add(keyPath);
      }
      _debouncedSave();
    }
  }

  /// Reset all entry to defaults if [saveDefaultValue] is true or clears it if not.
  void resetAll() {
    _inMemoryCache.clear();

    // If saving defaults, restore the defaults template
    if (saveDefaultValue && _allEntryDefaultCache.isNotEmpty) {
      _inMemoryCache.addAll(
        jsonDecode(jsonEncode(_allEntryDefaultCache)) as Map<String, dynamic>,
      );
    }

    _isCacheNeedsSave = true;
    if (_changeController.isClosed == false) {
      _changeController.add(const []); // Notify all listeners
    }
    _debouncedSave();
  }

  /// Returns whether a configuration entry exists at [keyPath].
  bool containsKey(List<String> keyPath) {
    if (keyPath.isEmpty) return false;

    dynamic currentCache = raw;

    for (int i = 0; i < keyPath.length - 1; i++) {
      if (currentCache is! Map) return false;
      currentCache = currentCache[keyPath[i]];
    }

    return currentCache is Map && currentCache.containsKey(keyPath.last);
  }

  /// Returns a broadcast stream that emits change events affecting [keyPath].
  ///
  /// Emits the `changedPath` whenever:
  /// - An exact match occurs (the entry at [keyPath] itself was modified or removed).
  /// - A parent group path is overwritten or removed (e.g. writing `['audio']` when watching
  ///   `['audio', 'volume']`).
  /// - All settings were cleared via [resetAll] (emitting an empty list `const []`).
  Stream<List<String>> watchKey(List<String> keyPath) {
    return _changeController.stream.where((changedPath) {
      if (changedPath.isEmpty) return true;
      if (changedPath.length > keyPath.length) return false;

      for (int i = 0; i < changedPath.length; i++) {
        if (keyPath[i] != changedPath[i]) return false;
      }
      return true;
    });
  }

  /// Starts watching [storedConfigFile] for external modifications.
  ///
  /// Watches the parent directory to detect in-place edits as well as atomic
  /// file save (safe saves) performed by modern text editors.
  void watchConfigFile({Duration debounceDuration = const Duration(milliseconds: 100)}) {
    final configFile = _storedConfigFile;
    if (configFile == null || _configFileWatcherSub != null) return;

    final parentDir = configFile.parent;
    if (!parentDir.existsSync()) {
      parentDir.createSync(recursive: true);
    }

    bool isTargetFile(String path) {
      return File(path).absolute.path.replaceAll(r'\', '/') ==
          configFile.absolute.path.replaceAll(r'\', '/');
    }

    _configFileWatcherSub = parentDir.watch().listen(
      (event) {
        // Match direct modifications as well as move/rename destinations (atomic editor saves)
        bool isTarget = isTargetFile(event.path);
        if (!isTarget && event is FileSystemMoveEvent && event.destination != null) {
          isTarget = isTargetFile(event.destination!);
        }

        // Ignore unrelated files or events triggered by internal flushes
        if (!isTarget || _isFlushing) return;

        _configFileReloadTimer?.cancel();
        _configFileReloadTimer = Timer(debounceDuration, _handleExternalFileChange);
      },
      onError: (Object error, StackTrace stackTrace) => onError?.call(error, stackTrace),
    );
  }

  Future<void> _handleExternalFileChange() async {
    final configFile = _storedConfigFile;
    if (_isFlushing || configFile == null) return;

    String? content;
    // Retry briefly to handle transient file lock contention (common on Windows during editor saves)
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        if (!await configFile.exists()) return;
        content = await configFile.readAsString();
        break;
      } on FileSystemException {
        if (attempt == 2) return;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }

    // Echo prevention: ignore if file content matches what we last flushed
    if (content == null || content == _lastFlushedContent) return;

    final dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (e, s) {
      onError?.call(e, s);
      return;
    }

    if (decoded is! Map<String, dynamic>) {
      onError?.call(
        const FormatException('Config file content is not a JSON object.'),
        StackTrace.current,
      );
      return;
    }

    // Disk wins: cancel pending debounced saves, update cache, and dispatch events to streams
    _debouncedTimer?.cancel();
    _isCacheNeedsSave = false;
    _lastFlushedContent = content;

    final changedPaths = diffKeyPaths(_inMemoryCache, decoded);
    _inMemoryCache.clear();
    _inMemoryCache.addAll(decoded);

    if (!_changeController.isClosed) {
      for (final path in changedPaths) {
        _changeController.add(path);
      }
    }

    _log('Reloaded configuration from disk (${changedPaths.length} setting(s) changed).');
  }

  void _debouncedSave() {
    if (_storedConfigFile == null) return;

    _debouncedTimer?.cancel();
    _debouncedTimer = Timer(debounceDuration, flush);
  }

  /// Persists pending in-memory configuration changes to disk immediately.
  ///
  /// Cancels any active debounce timer and (atomic) writes in-memory cache
  /// Does nothing if there are no unsaved changes or if running TypedConfig.inMemory().
  Future<void> flush() async {
    if (_storedConfigFile == null || _isCacheNeedsSave == false || _isFlushing) return;
    _debouncedTimer?.cancel();
    _isFlushing = true;

    File tempConfig = File('${_storedConfigFile.path}.tmp');

    try {
      if (await _storedConfigFile.parent.exists() == false) {
        await _storedConfigFile.parent.create(recursive: true);
      }

      final jsonEncoder = JsonEncoder.withIndent('  ');
      final encodedCache = jsonEncoder.convert(_inMemoryCache);

      await tempConfig.writeAsString(encodedCache, flush: true);

      try {
        await tempConfig.rename(_storedConfigFile.path);
      } on FileSystemException {
        await tempConfig.copy(_storedConfigFile.path);
        await tempConfig.delete();
      }

      _isCacheNeedsSave = false;
      _lastFlushedContent = encodedCache;
      _log('Saved configuration to ${_storedConfigFile.path}');
    } catch (e, s) {
      try {
        if (await tempConfig.exists()) await tempConfig.delete();
      } catch (_) {}
      onError?.call(e, s);
    } finally {
      _isFlushing = false;
    }
  }

  void dispose() {
    _configFileReloadTimer?.cancel();
    _configFileWatcherSub?.cancel();
    _debouncedTimer?.cancel();
    _changeController.close();

    if (_storedConfigFile != null && _isCacheNeedsSave) {
      try {
        if (_storedConfigFile.parent.existsSync() == false) {
          _storedConfigFile.parent.createSync(recursive: true);
        }

        final jsonEncoder = JsonEncoder.withIndent('  ');
        final encodedCache = jsonEncoder.convert(_inMemoryCache);
        _storedConfigFile.writeAsStringSync(encodedCache, flush: true);

        _isCacheNeedsSave = false;
        _lastFlushedContent = encodedCache;
        _log('Synchronously saved configuration on dispose.');
      } catch (e, s) {
        onError?.call(e, s);
      }
    }
  }
}

/// Recursively computes which key paths changed between [oldMap] and [newMap].
@internal
@visibleForTesting
List<List<String>> diffKeyPaths(
  Map<String, dynamic> oldMap,
  Map<String, dynamic> newMap, {
  List<String> prefix = const [],
}) {
  final changedPaths = <List<String>>[];
  final allKeys = {...oldMap.keys, ...newMap.keys};

  for (final key in allKeys) {
    final currentPath = [...prefix, key];
    final hasOld = oldMap.containsKey(key);
    final hasNew = newMap.containsKey(key);

    if (!hasOld && hasNew) {
      changedPaths.add(currentPath);
    } else if (hasOld && !hasNew) {
      changedPaths.add(currentPath);
    } else {
      final oldVal = oldMap[key];
      final newVal = newMap[key];

      if (oldVal is Map && newVal is Map) {
        changedPaths.addAll(
          diffKeyPaths(
            Map<String, dynamic>.from(oldVal),
            Map<String, dynamic>.from(newVal),
            prefix: currentPath,
          ),
        );
      } else if (!const DeepCollectionEquality().equals(oldVal, newVal)) {
        changedPaths.add(currentPath);
      }
    }
  }

  return changedPaths;
}
