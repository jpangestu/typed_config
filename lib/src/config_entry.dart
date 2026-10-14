import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'config_engine.dart';

const DeepCollectionEquality _entryDeepEquality = DeepCollectionEquality();

Type _typeOf<X>() => X;

final Type _nullableDoubleType = _typeOf<double?>();
final Type _nullableIntType = _typeOf<int?>();

/// A strongly-typed configuration entry handle.
///
/// Provides synchronous reads via [value], immediate in-memory updates with
/// debounced atomic disk persistence via [value]=, and selective change listening via [changes].
final class ConfigEntry<T> {
  /// Unique identifier used as the JSON map key (e.g. `'audio.volume'`).
  final String key;

  /// Fallback value returned when the entry is absent or invalid in storage.
  final T defaultValue;

  final ConfigEngine _engine;

  /// Optional deserializer to convert raw JSON into [T].
  final T Function(dynamic json)? fromJson;

  /// Optional serializer to convert [T] into a JSON-encodable object.
  final dynamic Function(T value)? toJson;

  @internal
  ConfigEntry({
    required this.key,
    required this.defaultValue,
    required ConfigEngine engine,
    this.fromJson,
    this.toJson,
  }) : _engine = engine;

  /// Synchronously returns the typed value from memory.
  ///
  /// Falls back to [defaultValue] if the entry is not explicitly set in the cache.
  T get value {
    final raw = _engine.readRaw(key);
    if (raw == null) {
      if (null is T && _engine.containsKey(key)) {
        return null as T;
      }
      return defaultValue;
    }
    return parse(raw);
  }

  /// Updates this setting in memory immediately and schedules a debounced disk save.
  set value(T newValue) {
    _engine.writeRaw(key, serialize(newValue));
  }

  /// Reverts this setting back to [defaultValue] and schedules a disk save.
  void reset() {
    _engine.resetKey(key);
  }

  /// Whether this entry has an explicitly stored value in memory.
  bool get isModified => _engine.containsKey(key);

  /// Broadcast stream that emits the latest typed value whenever this entry changes.
  ///
  /// Ignores changes to unrelated entries and deduplicates identical consecutive values.
  Stream<T> get changes =>
      _engine.watchKey(key).map((_) => value).distinct(_entryDeepEquality.equals);

  /// Parses raw JSON into [T], safely falling back to [defaultValue].
  T parse(dynamic json) {
    if (json == null) {
      if (null is T && _engine.containsKey(key)) {
        return null as T;
      }
      return defaultValue;
    }
    if (fromJson != null) {
      try {
        return fromJson!(json);
      } catch (e, s) {
        _engine.logError('Failed to parse key "$key"', e, s);
        return defaultValue;
      }
    }
    // Handle JSON num-to-double coercion (including nullable double?)
    if ((T == double || T == _nullableDoubleType) && json is num) {
      return json.toDouble() as T;
    }
    // Handle JSON num-to-int coercion (including nullable int?)
    if ((T == int || T == _nullableIntType) && json is num) {
      return json.toInt() as T;
    }
    if (json is T) return json;
    return defaultValue;
  }

  /// Serializes [val] into a JSON-encodable format.
  dynamic serialize(T val) {
    if (val == null && null is T) return null;
    if (toJson != null) {
      try {
        return toJson!(val);
      } catch (e, s) {
        _engine.logError('Failed to serialize key "$key"', e, s);
        if (defaultValue == null && null is T) return null;
        return toJson!(defaultValue);
      }
    }
    return val;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConfigEntry<T> && identical(_engine, other._engine) && key == other.key;

  @override
  int get hashCode => Object.hash(identityHashCode(_engine), key);

  @override
  String toString() => 'ConfigEntry<$T>($key)';
}
