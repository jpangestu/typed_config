import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:typed_config/src/config.dart';
import 'package:typed_config/src/config_engine.dart';

/// A configuration construction context passed to [Config] constructors.
///
/// Used during application setup to declare strongly-typed [ConfigEntry] instances
/// and organized domain-driven [group]s with automatic key path prefixing.
class ConfigBuilder({
  @internal required final ConfigEngine engine,
  required final List<String> prefixPath,
}) {
  /// Defines a strongly-typed configuration entry.
  ///
  /// [key] is the name of the setting at the current hierarchy level.
  /// [defaultValue] is used when the setting is missing from storage or null.
  ///
  /// Provide [fromJson] and [toJson] for custom objects or types that need
  /// conversion to and from JSON primitives.
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
  /// [defaultValue] if invalid or absent.
  ConfigEntry<E> defineEnum<E extends Enum>(
    String key,
    E defaultValue, {
    required Iterable<E> values,
  }) {
    // Create a lookup map: {'system': ThemeMode.system, 'dark': ThemeMode.dark}
    final lookupTable = <String, E>{};
    for (final enumValue in values) {
      lookupTable[enumValue.name] = enumValue;
    }

    return define<E>(
      key,
      defaultValue,
      fromJson: (jsonValue) => lookupTable[jsonValue] ?? defaultValue,
      toJson: (enumValue) => enumValue.name,
    );
  }

  /// Defines a list configuration entry, automatically casting elements from JSON.
  ///
  /// For primitive lists (e.g. `String`, `int`, `double`), no converters are needed:
  /// ```dart
  /// late final tags = builder.defineList('tags', ['home', 'work']);
  /// ```
  ///
  /// For lists of custom objects, provide [itemFromJson] and [itemToJson]
  /// to convert each individual element:
  /// ```dart
  /// late final users = builder.defineList<User>(
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
        return json.cast<T>();
      },
      toJson: itemToJson != null ? (list) => list.map(itemToJson).toList() : null,
    );
  }

  /// Instantiates a nested [Config] group under the namespace [name].
  ///
  /// Entries declared within the returned group automatically have [name]
  /// prepended to their key path.
  G group<G extends Config>(String name, G Function(ConfigBuilder builder) create) {
    return create(ConfigBuilder(engine: engine, prefixPath: [...prefixPath, name]));
  }
}

/// The typed bridge between the application schema and the untyped [ConfigEngine].
///
/// [ConfigEntry] represents a leaf node in the configuration tree:
final class ConfigEntry<T>({
  required final List<String> keyPath,
  required final T defaultValue,
  final T Function(dynamic json)? fromJson,
  final dynamic Function(T value)? toJson,
  required final ConfigEngine _engine,
}) {
  /// The current value of this configuration setting.
  ///
  /// Returns the in-memory cached value, or [defaultValue] if unset.
  /// Updating this property writes to memory immediately and schedules a
  /// debounced disk save.
  T get value {
    final keyValue = _engine.read(keyPath);
    if (keyValue == null) return defaultValue;
    if (fromJson != null) return fromJson!(keyValue);
    return keyValue as T;
  }

  set value(T newValue) {
    final dynamic encodedValue = toJson != null ? toJson!(newValue) : newValue;
    _engine.write(keyPath, encodedValue);
  }

  /// Revert this entry value back to [defaultValue].
  void reset() => _engine.remove(keyPath);

  /// The dot-separated path identifier (e.g., 'audio.volume').
  String get key => keyPath.join('.');

  /// Whether this entry has been explicitly modified.
  bool get isModified => _engine.read(keyPath) != null;

  /// A broadcast stream that emits whenever this entry's value changes.
  ///
  /// Emits the new [value] each time this setting is modified or [reset].
  /// Consecutive duplicate values are ignored.
  ///
  /// Note: Only emits subsequent changes; does not emit the current value
  /// upon initial subscription.
  Stream<T> get changes =>
      _engine.watchKey(key).map((_) => value).distinct(const DeepCollectionEquality().equals);

  @override
  String toString() => 'ConfigEntry<$T>($key: $value)';
}
