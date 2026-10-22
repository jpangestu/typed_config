import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:typed_config/src/config_engine.dart';
import 'package:typed_config/src/typed_config.dart';

/// A config construction context passed to [TypedConfig] constructors.
///
/// Used during application setup to declare strongly-typed [ConfigEntry] instances
/// and organized domain-driven [group]s with automatic key path prefixing.
final class ConfigBuilder {
  @internal
  final ConfigEngine engine;

  /// The hierarchical key path segments prepended to entries defined in this builder.
  final List<String> prefixPath;

  /// Creates a [ConfigBuilder] with the given [engine] and [prefixPath].
  ConfigBuilder({
    @internal required this.engine,
    required this.prefixPath,
  });

  /// Defines a strongly-typed configuration entry.
  ///
  /// [key] is the name of the config at the current hierarchy level.
  /// [defaultValue] is used when the config is invalid or missing from storage.
  ///
  /// Provide [fromJson] and [toJson] for custom objects or types that need
  /// conversion to and from JSON. Built-in types (int, double, string, bool)
  /// will be handled automatically.
  ConfigEntry<T> define<T>(
    String key,
    T defaultValue, {
    T Function(dynamic json)? fromJson,
    dynamic Function(T value)? toJson,
  }) {
    return ConfigEntry(
      keyPath: [...prefixPath, key],
      defaultValue: defaultValue,
      engine: engine,
      fromJson: fromJson,
      toJson: toJson,
    );
  }

  /// Defines an enum configuration entry with automatic string serialization.
  ///
  /// Matches stored JSON string values against [values] and falls back to
  /// [defaultValue] if the stored value is invalid or absent.
  ///
  /// Pass the enum's static `.values` list to [values] (required for name lookup):
  /// ```dart
  /// enum ThemeMode { system, light, dark }
  ///
  /// final theme = builder.defineEnum(
  ///   'theme',
  ///   ThemeMode.system,
  ///   values: ThemeMode.values,
  /// );
  /// ```
  ConfigEntry<E> defineEnum<E extends Enum?>(
    String key,
    E defaultValue, {
    required Iterable<Enum> values,
  }) {
    final lookupTable = <String, E>{};
    for (final enumValue in values) {
      lookupTable[enumValue.name] = enumValue as E;
    }

    return define<E>(
      key,
      defaultValue,
      fromJson: (jsonValue) => lookupTable[jsonValue] ?? defaultValue,
      toJson: (enumValue) => (enumValue as Enum?)?.name,
    );
  }

  /// Defines a list configuration entry, automatically casting elements from JSON.
  ///
  /// For primitive lists (e.g. `String`, `int`, `double`), no converters are needed:
  /// ```dart
  /// final tags = builder.defineList('tags', ['home', 'work']);
  /// ```
  ///
  /// For lists of custom objects, provide [itemFromJson] and [itemToJson]
  /// to convert each individual element:
  /// ```dart
  /// final users = builder.defineList<User>(
  ///   'users',
  ///   [],
  ///   itemFromJson: User.fromJson,
  ///   itemToJson: (user) => user.toJson(),
  /// );
  /// ```
  ConfigEntry<List<T>> defineList<T>(
    String key,
    List<T> defaultValue, {
    T Function(dynamic json)? itemFromJson,
    dynamic Function(T value)? itemToJson,
  }) {
    return define<List<T>>(
      key,
      defaultValue,
      fromJson: (json) {
        if (json is! List) return defaultValue;
        if (itemFromJson != null) {
          return json.map(itemFromJson).toList();
        }
        if (T == double) {
          return json.map((e) => (e as num).toDouble()).cast<T>().toList();
        }
        return json.cast<T>().toList();
      },
      toJson: itemToJson != null ? (list) => list.map(itemToJson).toList() : null,
    );
  }

  /// Instantiates a nested [TypedConfig] group under the namespace [name].
  ///
  /// Entries declared within the returned group automatically have [name]
  /// prepended to their key path.
  G group<G extends TypedConfig>(String name, G Function(ConfigBuilder builder) create) {
    return create(ConfigBuilder(engine: engine, prefixPath: [...prefixPath, name]));
  }
}

/// The typed bridge between the application schema and the untyped [ConfigEngine].
///
/// [ConfigEntry] represents a leaf node in the configuration tree:
final class ConfigEntry<T> {
  /// The hierarchical sequence of keys identifying this entry in storage.
  final List<String> keyPath;

  /// The fallback value used when the setting is missing from storage or corrupted.
  final T defaultValue;

  /// Optional converter from raw JSON primitives to type [T].
  final T Function(dynamic json)? fromJson;

  /// Optional converter from type [T] to JSON-serializable primitives.
  final dynamic Function(T value)? toJson;

  final ConfigEngine _engine;

  /// Creates a [ConfigEntry] bound to [keyPath] and backed by [engine].
  ConfigEntry({
    required this.keyPath,
    required this.defaultValue,
    required ConfigEngine engine,
    this.fromJson,
    this.toJson,
  }) : _engine = engine;

  /// The current value of this configuration setting.
  ///
  /// Returns the in-memory cached value, or [defaultValue] if unset.
  /// Updating this property writes to memory immediately and schedules a
  /// debounced disk save.
  T get value {
    if (!_engine.containsKey(keyPath)) return defaultValue;
    final keyValue = _engine.read(keyPath);
    if (keyValue == null) {
      if (null is T) return null as T;
      return defaultValue;
    }
    if (fromJson != null) {
      try {
        return fromJson!(keyValue);
      } catch (_) {
        return defaultValue;
      }
    }
    if (keyValue is T) return keyValue;
    if (T == double && keyValue is num) {
      return keyValue.toDouble() as T;
    }
    return defaultValue;
  }

  set value(T newValue) {
    final dynamic encodedValue = newValue != null && toJson != null ? toJson!(newValue) : newValue;
    _engine.write(keyPath, encodedValue);
  }

  /// Revert this entry value back to [defaultValue].
  void reset() => _engine.remove(keyPath);

  /// Whether this entry has been explicitly modified.
  bool get isModified => _engine.containsKey(keyPath);

  /// A broadcast stream that emits whenever this entry's value changes.
  ///
  /// Emits the new [value] each time this setting is modified, [reset], or affected
  /// by a parent group modification. Consecutive duplicate values are ignored using
  /// deep collection equality.
  ///
  /// Note: Only emits subsequent changes; does not emit the current value
  /// upon initial subscription.
  Stream<T> get changes =>
      _engine.watchKey(keyPath).map((_) => value).distinct(const DeepCollectionEquality().equals);

  @override
  String toString() => 'ConfigEntry<$T>($keyPath: $value)';
}
