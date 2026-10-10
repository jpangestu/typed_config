import 'package:meta/meta.dart';

/// A strongly-typed configuration entry with fallback defaults and serialization rules.
///
/// Use [ConfigEntry] to define configuration schema entries.
/// When parsed from JSON, values are validated and coerced to [T], safely falling
/// back to [defaultValue] if missing, null, or malformed.
@immutable
class const ConfigEntry<T>({
  /// Unique identifier used as the JSON map key.
  required final String key,

  /// Fallback value returned when the entry is absent or invalid in storage.
  required final T defaultValue,

  /// Optional deserializer to convert raw JSON into
  ///  [T].
  final T Function(dynamic json)? fromJson,

  /// Optional serializer to convert [T] into a JSON-encodable object.
  final dynamic Function(T value)? toJson,
}) {
  /// Parses raw JSON into [T], safely falling back to [defaultValue].
  ///
  /// Automatically coerces [num] to [double] or [int], and raw lists to
  /// unmodifiable `List<String>`. Safely catches any exceptions from [fromJson].
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

  /// Serializes [value] into a JSON-encodable format.
  ///
  /// Safely catches any exceptions from [toJson] and falls back to serializing [defaultValue].
  dynamic serialize(T value) {
    if (toJson != null) {
      try {
        return toJson!(value);
      } catch (_) {
        if (toJson != null) {
          try {
            return toJson!(defaultValue);
          } catch (_) {}
        }
        return defaultValue;
      }
    }
    return value;
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
