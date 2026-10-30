import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, FileSystemException;

import 'package:collection/collection.dart';

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
  bool _isCacheNeedsSave = false;
  bool _isFlushing = false;
  Timer? _debouncedTimer;
  final StreamController<List<String>> _changeController = StreamController.broadcast();

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
        _log('Synchronously saved configuration on dispose.');
      } catch (e, s) {
        onError?.call(e, s);
      }
    }
  }
}
