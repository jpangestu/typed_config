import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';

import 'config.dart';
import 'config_entry.dart';

/// A configuration construction context passed to class primary constructors.
///
/// Used during application bootstrap to build strongly-typed [ConfigEntry] instances
/// and organized domain-driven groups with automatic dot-separated key prefixing.
final class ConfigBuilder {
  /// The current namespace prefix (e.g. `'audio'` or empty string `''` for root).
  final String prefix;

  final ConfigBuilder? _parent;
  Config? _config;

  @internal
  final File? file;

  @internal
  final Map<String, dynamic> cache;

  @internal
  final StreamController<String> keyChanges;

  @internal
  final void Function(String message)? onLog;

  @internal
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// Creates a builder tied to an existing [Config] instance.
  ConfigBuilder(this.prefix, Config config)
    : _parent = null,
      _config = config,
      file = config.file,
      cache = config.cache,
      keyChanges = config.keyChanges,
      onLog = config.onLog,
      onError = config.onError;

  /// Internal constructor used during initialization before [Config] is fully constructed.
  @internal
  ConfigBuilder.initialize({
    required this.prefix,
    ConfigBuilder? parent,
    this.file,
    Map<String, dynamic>? cache,
    StreamController<String>? keyChanges,
    this.onLog,
    this.onError,
  }) : _parent = parent,
       cache = cache ?? parent?.cache ?? <String, dynamic>{},
       keyChanges = keyChanges ?? parent?.keyChanges ?? StreamController<String>.broadcast();

  /// Binds the constructed [Config] instance to this root builder.
  @internal
  void bind(Config config) {
    _config = config;
  }

  /// The active [Config] instance for this builder.
  @internal
  Config get config {
    final c = _config ?? _parent?.config;
    if (c == null) {
      throw StateError('ConfigBuilder has not been bound to a Config instance.');
    }
    return c;
  }

  /// Creates a scoped child builder with an added namespace prefix (e.g. `withPrefix('audio')` -> `'audio'`).
  ConfigBuilder withPrefix(String name) {
    final childPrefix = prefix.isEmpty ? name : '$prefix.$name';
    final child = ConfigBuilder.initialize(
      prefix: childPrefix,
      parent: this,
      file: file,
      cache: cache,
      keyChanges: keyChanges,
      onLog: onLog,
      onError: onError,
    );
    if (_config != null) {
      child.bind(_config!);
    }
    return child;
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
      builder: this,
      fromJson: fromJson,
      toJson: toJson,
    );
  }

  /// Defines an enum configuration entry with automatic string serialization.
  ///
  /// Optionally supply [values] to match against all enum cases.
  ConfigEntry<E> defineEnum<E extends Enum>(String key, E defaultValue, {Iterable<E>? values}) {
    final fullKey = prefix.isEmpty ? key : '$prefix.$key';
    return ConfigEntry<E>(
      key: fullKey,
      defaultValue: defaultValue,
      builder: this,
      fromJson: (j) {
        if (j is String) {
          if (values != null) {
            for (final v in values) {
              if (v.name == j) return v;
            }
          }
          if (defaultValue.name == j) return defaultValue;
        }
        return defaultValue;
      },
      toJson: (e) => e.name,
    );
  }

  /// Defines a list configuration entry, defensively wrapped in unmodifiable views.
  ConfigEntry<List<T>> defineList<T>(String key, List<T> defaultValue) {
    final fullKey = prefix.isEmpty ? key : '$prefix.$key';
    return ConfigEntry<List<T>>(
      key: fullKey,
      defaultValue: List<T>.unmodifiable(defaultValue),
      builder: this,
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
