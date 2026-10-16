import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, FileSystemException;

class ConfigEngine({
  final File? _storedConfigFile,
  required final Map<String, dynamic> _inMemoryCache,
  Duration? debounceDuration,
  final void Function(String message)? onLog,
  final void Function(Object error, StackTrace stackTrace)? onError,
}) {
  final Duration debounceDuration = debounceDuration ?? const Duration(milliseconds: 300);
  bool _isCacheNeedsSave = false;
  Timer? _debouncedTimer;
  final StreamController<String> _changeController = StreamController.broadcast();

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

    for (int i = 0; i < keyPath.length - 1; i++) {
      final segmentKey = keyPath[i];
      final next = currentCache[segmentKey];

      if (next is Map<String, dynamic>) {
        currentCache = next;
      } else {
        // If missing or not a map, create a fresh map.
        final newMap = <String, dynamic>{};
        currentCache[segmentKey] = newMap;
        currentCache = newMap;
      }
    }

    currentCache[keyPath.last] = value;

    _isCacheNeedsSave = true;
    _changeController.add(keyPath.join('.'));
    _debouncedSave();
  }

  void remove(List<String> keyPath) {
    if (keyPath.isEmpty) return;

    dynamic currentCache = _inMemoryCache;
    // Traverse to the parent map of the leaf key in key path
    for (int i = 0; i < keyPath.length - 1; i++) {
      if (currentCache is! Map) return;
      currentCache = currentCache[keyPath[i]];
    }
    // Remove the leaf key
    if (currentCache is Map && currentCache.containsKey(keyPath.last)) {
      currentCache.remove(keyPath.last);

      _isCacheNeedsSave = true;
      _changeController.add(keyPath.join('.'));
      _debouncedSave();
    }
  }

  /// Clears all in-memory configuration overrides and notifies all key watchers.
  void resetAll() {
    _inMemoryCache.clear();
    _isCacheNeedsSave = true;
    _changeController.add('*');
    _debouncedSave();
  }

  Stream<String> watchKey(String key) {
    return _changeController.stream.where(
      (changedKey) => changedKey == key || changedKey == '*',
    );
  }

  void _debouncedSave() {
    if (_storedConfigFile == null) return;

    _debouncedTimer?.cancel();
    _debouncedTimer = Timer(debounceDuration, flush);
  }

  /// Persists pending in-memory configuration changes to disk immediately.
  ///
  /// Cancels any active debounce timer and (atomic) writes in-memory cache
  /// Does nothing if running in-memory or if there are no unsaved changes.
  Future<void> flush() async {
    if (_storedConfigFile == null || !_isCacheNeedsSave) return;
    _debouncedTimer?.cancel();

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
