import 'package:meta/meta.dart';

import 'config_engine.dart';
import 'config_entry.dart';
import 'config_migration.dart';

Type _typeOf<X>() => X;

final Type _nullableDoubleType = _typeOf<double?>();
final Type _nullableIntType = _typeOf<int?>();

/// A configuration construction context passed to class primary constructors.
///
/// Used during application bootstrap to build strongly-typed [ConfigEntry] instances
/// and organized domain-driven groups with automatic dot-separated key prefixing.
final class ConfigBuilder {
  /// Reference to the active configuration engine.
  @internal
  final ConfigEngine engine;

  /// The current namespace prefix (e.g. `'audio'` or empty string `''` for root).
  final String prefix;

  /// Creates a builder tied to an active [ConfigEngine].
  @internal
  ConfigBuilder(this.engine, [this.prefix = '']);

  static void _validateSegment(String segment, String paramName) {
    if (segment.isEmpty ||
        segment.startsWith('.') ||
        segment.endsWith('.') ||
        segment.contains('..')) {
      throw ArgumentError.value(
        segment,
        paramName,
        'Key segment must be non-empty and cannot start/end with "." or contain "..".',
      );
    }
  }

  String _resolveKey(String key) {
    _validateSegment(key, 'key');
    final fullKey = prefix.isEmpty ? key : '$prefix.$key';
    if (fullKey == schemaVersionKey || fullKey.startsWith('$schemaVersionKey.')) {
      throw ArgumentError.value(
        fullKey,
        'key',
        '"$schemaVersionKey" is reserved for internal schema tracking.',
      );
    }
    return fullKey;
  }

  /// Creates a scoped child builder with an added namespace prefix (e.g. `withPrefix('audio')` -> `'audio'`).
  ConfigBuilder withPrefix(String name) {
    _validateSegment(name, 'name');
    final childPrefix = prefix.isEmpty ? name : '$prefix.$name';
    if (childPrefix == schemaVersionKey || childPrefix.startsWith('$schemaVersionKey.')) {
      throw ArgumentError.value(
        childPrefix,
        'name',
        '"$schemaVersionKey" is reserved for internal schema tracking.',
      );
    }
    return ConfigBuilder(engine, childPrefix);
  }

  /// Defines a strongly-typed configuration entry.
  ConfigEntry<T> define<T>(
    String key,
    T defaultValue, {
    T Function(dynamic json)? fromJson,
    dynamic Function(T value)? toJson,
  }) {
    final fullKey = _resolveKey(key);
    return ConfigEntry<T>(
      key: fullKey,
      defaultValue: defaultValue,
      engine: engine,
      fromJson: fromJson,
      toJson: toJson,
    );
  }

  /// Defines an enum configuration entry with automatic string serialization.
  ///
  /// Matches against [values] in O(1) time and falls back to [defaultValue] if invalid or absent.
  ConfigEntry<E> defineEnum<E extends Enum>(
    String key,
    E defaultValue, {
    required Iterable<E> values,
  }) {
    final fullKey = _resolveKey(key);
    final lookup = {for (final v in values) v.name: v};
    return ConfigEntry<E>(
      key: fullKey,
      defaultValue: defaultValue,
      engine: engine,
      fromJson: (j) => j is String ? (lookup[j] ?? defaultValue) : defaultValue,
      toJson: (e) => e.name,
    );
  }

  /// Defines a list configuration entry, defensively wrapped in unmodifiable views.
  ConfigEntry<List<T>> defineList<T>(String key, List<T> defaultValue) {
    final fullKey = _resolveKey(key);
    final unmodifiableDefault = List<T>.unmodifiable(defaultValue);
    final isDoubleElem = T == double || T == _nullableDoubleType;
    final isIntElem = T == int || T == _nullableIntType;

    return ConfigEntry<List<T>>(
      key: fullKey,
      defaultValue: unmodifiableDefault,
      engine: engine,
      fromJson: (json) {
        if (json is! List) return unmodifiableDefault;
        try {
          final parsed = <T>[];
          for (final item in json) {
            if (item == null && null is T) {
              parsed.add(null as T);
            } else if (isDoubleElem && item is num) {
              parsed.add(item.toDouble() as T);
            } else if (isIntElem && item is num) {
              parsed.add(item.toInt() as T);
            } else if (item is T) {
              parsed.add(item);
            } else {
              throw FormatException(
                'Invalid list element "${item.runtimeType}" for List<$T> in key "$fullKey".',
              );
            }
          }
          return List<T>.unmodifiable(parsed);
        } catch (e, s) {
          engine.logError('Failed to parse list for key "$fullKey"', e, s);
          return unmodifiableDefault;
        }
      },
      toJson: (val) => List<T>.unmodifiable(val),
    );
  }
}
