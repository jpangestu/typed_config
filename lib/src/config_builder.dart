import 'package:meta/meta.dart';

import 'config.dart';
import 'config_engine.dart';
import 'config_entry.dart';
import 'config_migration.dart';

bool _isRawCollectionType<T>(T defaultValue) {
  if (defaultValue is List || defaultValue is Map) return true;
  final typeStr = T.toString();
  return T == List || T == Map || typeStr.startsWith('List<') || typeStr.startsWith('Map<');
}

T _freezeTypedElement<T>(T element) {
  if (element is List || element is Map) {
    final frozen = freezeConfigValue(element);
    if (frozen is T) return frozen;
  }
  return element;
}

/// A configuration construction context passed to class constructors.
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

  String _resolveKey(String key) {
    validateKeySegment(key, 'key');
    final fullKey = prefix.isEmpty ? key : '$prefix.$key';
    validateConfigKey(fullKey, 'key');
    engine.registerKey(fullKey);
    return fullKey;
  }

  /// Creates a scoped child builder with an added namespace prefix (e.g. `withPrefix('audio')` -> `'audio'`).
  ConfigBuilder withPrefix(String name) {
    validateKeySegment(name, 'name');
    final childPrefix = prefix.isEmpty ? name : '$prefix.$name';
    validateConfigKey(childPrefix, 'name');
    engine.registerGroup(childPrefix);
    return ConfigBuilder(engine, childPrefix);
  }

  /// Instantiates a nested [Config] group under the namespace [name].
  G group<G extends Config>(String name, G Function(ConfigBuilder builder) create) {
    return create(withPrefix(name));
  }

  /// Defines a strongly-typed configuration entry.
  ///
  /// For `List` or `Map` entries without custom `fromJson`/`toJson` converters,
  /// use [defineList] or [defineMap] instead.
  ConfigEntry<T> define<T>(
    String key,
    T defaultValue, {
    T Function(dynamic json)? fromJson,
    dynamic Function(T value)? toJson,
  }) {
    if (fromJson == null && _isRawCollectionType<T>(defaultValue)) {
      throw ArgumentError.value(
        key,
        'key',
        'Use defineList() or defineMap() (or provide custom fromJson/toJson) for collection type $T.',
      );
    }
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
      isFlatLeaf: true,
    );
  }

  /// Defines a list configuration entry, defensively wrapped in unmodifiable views.
  ///
  /// Optionally accepts [itemFromJson] and [itemToJson] for custom element types.
  ConfigEntry<List<T>> defineList<T>(
    String key,
    List<T> defaultValue, {
    T Function(dynamic json)? itemFromJson,
    dynamic Function(T value)? itemToJson,
  }) {
    final fullKey = _resolveKey(key);
    final unmodifiableDefault = List<T>.unmodifiable(
      defaultValue.map(_freezeTypedElement<T>),
    );
    final isDoubleElem = T == double || T == nullableDoubleType;
    final isIntElem = T == int || T == nullableIntType;

    return ConfigEntry<List<T>>(
      key: fullKey,
      defaultValue: unmodifiableDefault,
      engine: engine,
      isFlatLeaf: true,
      fromJson: (json) {
        if (json is! List) return unmodifiableDefault;
        try {
          final parsed = <T>[];
          for (final item in json) {
            if (item == null && null is T) {
              parsed.add(null as T);
            } else if (itemFromJson != null) {
              parsed.add(itemFromJson(item));
            } else if (isDoubleElem && item is num) {
              parsed.add(item.toDouble() as T);
            } else if (isIntElem && item is num) {
              parsed.add(item.toInt() as T);
            } else if (item is T) {
              parsed.add(_freezeTypedElement<T>(item));
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
      toJson: itemToJson != null
          ? (val) => List<dynamic>.unmodifiable(
                val.map((e) => (e == null && null is T) ? null : itemToJson(e)),
              )
          : (val) => List<T>.unmodifiable(val.map(_freezeTypedElement<T>)),
    );
  }

  /// Defines a strongly-typed map configuration entry (`Map<String, V>`), defensively
  /// wrapped in unmodifiable views.
  ///
  /// Because maps are flattened into dot-separated keys in storage, map keys in
  /// [defaultValue] and runtime values must be non-empty and cannot contain `'.'`.
  /// Optionally accepts [valueFromJson] and [valueToJson] for custom value types.
  ConfigEntry<Map<String, V>> defineMap<V>(
    String key,
    Map<String, V> defaultValue, {
    V Function(dynamic json)? valueFromJson,
    dynamic Function(V value)? valueToJson,
  }) {
    for (final k in defaultValue.keys) {
      if (k.isEmpty || k.contains('.')) {
        throw ArgumentError.value(
          k,
          'defaultValue',
          'Map keys stored in Config cannot be empty or contain ".".',
        );
      }
    }
    final fullKey = _resolveKey(key);
    final unmodifiableDefault = Map<String, V>.unmodifiable({
      for (final entry in defaultValue.entries) entry.key: _freezeTypedElement<V>(entry.value),
    });
    final isDoubleVal = V == double || V == nullableDoubleType;
    final isIntVal = V == int || V == nullableIntType;

    return ConfigEntry<Map<String, V>>(
      key: fullKey,
      defaultValue: unmodifiableDefault,
      engine: engine,
      isFlatLeaf: false,
      fromJson: (json) {
        if (json is! Map) return unmodifiableDefault;
        try {
          final parsed = <String, V>{};
          for (final entry in json.entries) {
            final k = entry.key.toString();
            final val = entry.value;
            if (val == null && null is V) {
              parsed[k] = null as V;
            } else if (valueFromJson != null) {
              parsed[k] = valueFromJson(val);
            } else if (isDoubleVal && val is num) {
              parsed[k] = val.toDouble() as V;
            } else if (isIntVal && val is num) {
              parsed[k] = val.toInt() as V;
            } else if (val is V) {
              parsed[k] = _freezeTypedElement<V>(val);
            } else {
              throw FormatException(
                'Invalid map value "${val.runtimeType}" for Map<String, $V> at "$fullKey.$k".',
              );
            }
          }
          return Map<String, V>.unmodifiable(parsed);
        } catch (e, s) {
          engine.logError('Failed to parse map for key "$fullKey"', e, s);
          return unmodifiableDefault;
        }
      },
      toJson: valueToJson != null
          ? (val) => Map<String, dynamic>.unmodifiable({
                for (final e in val.entries)
                  e.key: (e.value == null && null is V) ? null : valueToJson(e.value),
              })
          : (val) => Map<String, V>.unmodifiable({
                for (final e in val.entries) e.key: _freezeTypedElement<V>(e.value),
              }),
    );
  }
}
