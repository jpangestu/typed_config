import 'package:riverpod/riverpod.dart';
import 'package:typed_config/typed_config.dart';

/// Provider supplying the active [Config] instance.
final configProvider = Provider<Config>((ref) {
  throw UnimplementedError(
    'configProvider must be overridden with an initialized Config instance: '
    'ProviderScope(overrides: [configProvider.overrideWithValue(config)])',
  );
});

/// A Riverpod [Notifier] that manages a single persistent configuration entry.
///
/// Reads its initial state synchronously from [Config], automatically synchronizes
/// with external file changes and wildcard resets, and triggers debounced disk writes
/// on mutation.
class ConfigNotifier<T>(final ConfigEntry<T> _entry) extends Notifier<T> {
  @override
  T build() {
    final config = ref.watch(configProvider);

    final sub = config.watch(_entry).listen((newValue) {
      if (state != newValue) {
        state = newValue;
      }
    });
    ref.onDispose(sub.cancel);

    return config.get(_entry);
  }

  /// Updates the setting to [value] in memory and schedules saving to disk.
  void set(T value) {
    state = value;
    ref.read(configProvider).set(_entry, value);
  }

  /// Reverts the setting to its default value and schedules saving to disk.
  void reset() {
    state = _entry.defaultValue;
    ref.read(configProvider).reset(_entry);
  }
}

/// Creates a strongly-typed, persistent [NotifierProvider] for a configuration entry.
NotifierProvider<ConfigNotifier<T>, T> configEntryProvider<T>({
  required String key,
  required T defaultValue,
  T Function(dynamic json)? fromJson,
  dynamic Function(T value)? toJson,
}) {
  final entry = ConfigEntry<T>(
    key: key,
    defaultValue: defaultValue,
    fromJson: fromJson,
    toJson: toJson,
  );
  return NotifierProvider<ConfigNotifier<T>, T>(() => ConfigNotifier<T>(entry));
}

/// Creates a persistent [NotifierProvider] from an existing [ConfigEntry].
NotifierProvider<ConfigNotifier<T>, T> configEntryProviderFromEntry<T>(
  ConfigEntry<T> entry,
) {
  return NotifierProvider<ConfigNotifier<T>, T>(() => ConfigNotifier<T>(entry));
}
