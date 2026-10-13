import 'config_engine.dart';

/// A strongly-typed configuration entry handle bound to an active configuration engine.
///
/// Provides synchronous reads via [value], immediate memory updates with
/// debounced atomic disk persistence via [value]=, and selective change listening.
final class ConfigEntry<T> {
  /// Unique identifier used as the JSON map key (e.g. `'audio.volume'`).
  final String key;

  /// Fallback value returned when the entry is absent or invalid in storage.
  final T defaultValue;

  /// Reference to the backing [ConfigEngine].
  final ConfigEngine engine;

  /// Optional deserializer to convert raw JSON into [T].
  final T Function(dynamic json)? fromJson;

  /// Optional serializer to convert [T] into a JSON-encodable object.
  final dynamic Function(T value)? toJson;

  ConfigEntry({
    required this.key,
    required this.defaultValue,
    required this.engine,
    this.fromJson,
    this.toJson,
  });

  /// Synchronously returns the typed value from memory.
  ///
  /// Falls back to [defaultValue] if the entry is not explicitly set in the cache.
  T get value {
    final raw = engine.readRaw(key);
    if (raw == null && !engine.containsKey(key)) {
      return defaultValue;
    }
    return parse(raw);
  }

  /// Updates this setting in memory immediately and schedules a debounced disk save.
  set value(T newValue) {
    engine.writeRaw(key, serialize(newValue));
  }

  /// Reverts this setting back to [defaultValue] and schedules a disk save.
  void reset() {
    engine.resetKey(key);
  }

  /// Whether this entry has an explicitly stored value in memory.
  bool get isModified => engine.containsKey(key);

  /// Broadcast stream that emits the latest typed value whenever this entry changes.
  ///
  /// Ignores changes to unrelated entries.
  Stream<T> get changes => engine.watchKey(key).map((_) => value);

  /// Parses raw JSON into [T], safely falling back to [defaultValue].
  T parse(dynamic json) {
    if (json == null) return defaultValue;
    if (fromJson != null) {
      try {
        return fromJson!(json);
      } catch (_) {
        return defaultValue;
      }
    }
    // Handle JSON num-to-double coercion
    if (defaultValue is double && json is num) {
      return json.toDouble() as T;
    }
    // Handle JSON num-to-int coercion
    if (defaultValue is int && json is num) {
      return json.toInt() as T;
    }
    // Handle JSON dynamic lists for List<String> entries
    if (defaultValue is List<String> && json is List) {
      try {
        final list = json.whereType<String>().toList();
        return List<String>.unmodifiable(list) as T;
      } catch (_) {
        return defaultValue;
      }
    }
    if (json is T) return json;
    return defaultValue;
  }

  /// Serializes [val] into a JSON-encodable format.
  dynamic serialize(T val) {
    if (toJson != null) {
      try {
        return toJson!(val);
      } catch (_) {
        return defaultValue;
      }
    }
    return val;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ConfigEntry<T> && key == other.key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'ConfigEntry<$T>($key)';
}
