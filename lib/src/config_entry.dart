import 'config.dart';
import 'config_builder.dart';

/// A strongly-typed configuration entry handle bound to a [Config] instance.
///
/// Provides synchronous reads via [value], immediate memory updates with
/// debounced atomic disk persistence via [value]=, and selective change listening.
final class ConfigEntry<T>({
  /// Unique identifier used as the JSON map key (e.g. `'audio.volume'`).
  required final String key,

  /// Fallback value returned when the entry is absent or invalid in storage.
  required final T defaultValue,

  /// Reference to the backing builder context.
  ConfigBuilder? builder,

  /// Direct reference to the backing [Config] engine.
  Config? config,

  /// Optional deserializer to convert raw JSON into [T].
  final T Function(dynamic json)? fromJson,

  /// Optional serializer to convert [T] into a JSON-encodable object.
  final dynamic Function(T value)? toJson,
}) {
  final ConfigBuilder? _builder = builder;
  final Config? _explicitConfig = config;

  /// Reference to the backing [Config] engine.
  Config get config {
    final direct = _explicitConfig;
    if (direct != null) return direct;
    final b = _builder;
    if (b != null) return b.config;
    throw StateError('ConfigEntry is not bound to a Config or ConfigBuilder.');
  }

  /// Synchronously returns the typed value from memory.
  ///
  /// Falls back to [defaultValue] if the entry is not explicitly set in the cache.
  T get value {
    if (!config.contains(this)) {
      return defaultValue;
    }
    return parse(config.readRaw(key));
  }

  /// Updates this setting in memory immediately and schedules a debounced disk save.
  set value(T newValue) {
    config.writeRaw(key, serialize(newValue));
  }

  /// Reverts this setting back to [defaultValue] and schedules a disk save.
  void reset() {
    config.resetKey(key);
  }

  /// Whether this entry has an explicitly stored value in memory.
  bool get isModified => config.contains(this);

  /// Broadcast stream that emits the latest typed value whenever this entry changes.
  ///
  /// Ignores changes to unrelated entries.
  Stream<T> get changes => config.watchKey(key).map((_) => value);

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
        if (toJson != null) {
          try {
            return toJson!(defaultValue);
          } catch (_) {}
        }
        return defaultValue;
      }
    }
    return val;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConfigEntry<T> && runtimeType == other.runtimeType && key == other.key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'ConfigEntry<$T>($key)';
}
