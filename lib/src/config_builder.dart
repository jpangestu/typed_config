import 'package:meta/meta.dart';

import 'config_engine.dart';
import 'config_entry.dart';

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

  /// Creates a scoped child builder with an added namespace prefix (e.g. `withPrefix('audio')` -> `'audio'`).
  ConfigBuilder withPrefix(String name) {
    final childPrefix = prefix.isEmpty ? name : '$prefix.$name';
    return ConfigBuilder(engine, childPrefix);
  }

  /// Defines a strongly-typed configuration entry.
  ConfigEntry<T> define<T>(
    String key,
    T defaultValue, {
    T Function(dynamic json)? fromJson,
    dynamic Function(T value)? toJson,
  }) {
    final fullKey = prefix.isEmpty ? key : '$prefix.$key';
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
    final fullKey = prefix.isEmpty ? key : '$prefix.$key';
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
    final fullKey = prefix.isEmpty ? key : '$prefix.$key';
    return ConfigEntry<List<T>>(
      key: fullKey,
      defaultValue: List<T>.unmodifiable(defaultValue),
      engine: engine,
      fromJson: (json) {
        if (json is List) {
          try {
            final list = json.whereType<T>().toList();
            return List<T>.unmodifiable(list);
          } catch (_) {
            return defaultValue;
          }
        }
        return defaultValue;
      },
      toJson: (val) => val,
    );
  }
}
