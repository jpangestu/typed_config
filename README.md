# typed_config
Manage and persist application configs (or settings, or preferences, or whatever you wanna call it) with first-class support for primitives, enums, and custom types. Saved to disk as JSON with safe background saves, schema migrations, and file corruption recovery.

## Features

- **Strictly Type-Safe:** Guarantees non-null values with compile-time type checking.
- **Synchronous Reads:** In-memory cache allows instant synchronous reads.
- **Debounced Background Saves:** 300ms debounce prevents disk thrashing on slider scrubbing or rapid typing.
- **Domain Groups & Auto-Namespacing:** Organize settings into modular classes (e.g., AudioSettings, UiSettings); keys are automatically namespaced ('audio.volume') and serialize into indented nested JSON on disk.
- **Schema Migrations:** Safely migrate configuration schemas sequentially between app releases ($v1 \rightarrow v2$).
- **Crash & Corruption Recovery:** Automatically quarantines malformed or damaged JSON files to `.corrupt` before restoring clean defaults.
- **Zero Framework Coupling:** Pure Dart library with no Flutter or UI dependencies.

## Usage

### 1. Define your config

Organize config into domain-driven groups (`ConfigBuilder`), then mount them on your root `Config`:

```dart
enum ThemeMode { system, light, dark }

// Main application config
class AppConfig(ConfigBuilder builder) extends Config {
  final language = builder.define('language', 'en');
  final autoCheckUpdates = builder.define('autoCheckUpdates', true);

  // If you want to organize your config into group
  final ui = UiSettings(builder.withPrefix('ui'));
}

// Grouped config
class UiSettings(ConfigBuilder builder) {
  final themeMode = builder.defineEnum('themeMode', ThemeMode.system, values: ThemeMode.values);
  final compactMode = builder.define('compactMode', false);
  final fontScale = builder.define('fontScale', 1.0);
}
```

> **Tip:** `builder.withPrefix('ui')` automatically prefixes child keys as `'ui.themeMode'`, formatting into indented nested objects on disk.

### 2. Initialize once in `main()`

Load your configuration file asynchronously once at app startup via constructor tear-off (`AppConfig.new`). After this call, all reads anywhere in your app are 100% synchronous:

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final supportDir = await getApplicationSupportDirectory();
  final configFile = File('${supportDir.path}/config.json');

  final config = await Config.initialize(
    AppConfig.new,
    configFile,
    schemaVersion: 1,
  );

  runApp(MyApp(config: config));
}
```

### 3. Read and write configs

```dart
// Synchronous read (no await, no FutureBuilder, no spinners)
final currentThemeMode = config.ui.themeMode.value;

// Update (immediate in memory, debounced in disk save)
config.ui.themeMode.value = ThemeMode.dark;

// Check if customized (useful for showing a "Reset" button)
print(config.ui.themeMode.isModified); // true

// Reset back to default
config.ui.themeMode.reset();
print(config.ui.themeMode.isModified); // false

// Reset all configs to defaults
await config.resetAll();

// Listen to changes for a specific config
config.ui.themeMode.changes.listen((newTheme) {
  print('Theme changed: $newTheme');
});
```

### 4. Unit Testing (In-Memory)

Instantiate your configuration in tests without file I/O or temporary directories:

```dart
void main() {
  test('theme update test', () {
    final config = Config.inMemory(AppConfig.new);

    expect(config.ui.themeMode.value, ThemeMode.system);
    config.ui.themeMode.value = ThemeMode.dark;
    expect(config.ui.themeMode.value, ThemeMode.dark);
  });
}
```

---

## Integrations

Because typed_config is pure Dart, you can easily bridge it to Flutter or your favorite state management solution.

### Riverpod Integration

You can bridge typed_config into Riverpod with this lightweight extension, allowing widgets to watch individual entries without rebuilding on unrelated config changes::

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:typed_config/typed_config.dart';

final _entryProviderCache = Expando<NotifierProvider<ConfigEntryNotifier<dynamic>, dynamic>>();

/// A Riverpod [Notifier] that synchronizes a single [ConfigEntry].
class ConfigEntryNotifier<T>(final ConfigEntry<T> _entry) extends Notifier<T> {
  @override
  T build() {
    final sub = _entry.changes.listen((newValue) {
      if (state != newValue) {
        state = newValue;
      }
    });
    ref.onDispose(sub.cancel);
    return _entry.value;
  }
}

/// Riverpod extension providing fine-grained, zero-boilerplate providers for [ConfigEntry].
extension ConfigEntryRiverpodX<T> on ConfigEntry<T> {
  /// Returns a cached [NotifierProvider] tied strictly to this entry.
  NotifierProvider<ConfigEntryNotifier<T>, T> get provider {
    final cached = _entryProviderCache[this];
    if (cached != null) {
      return cached as NotifierProvider<ConfigEntryNotifier<T>, T>;
    }
    final created = NotifierProvider<ConfigEntryNotifier<T>, T>(
      () => ConfigEntryNotifier<T>(this),
    );
    _entryProviderCache[this] = created;
    return created;
  }
}
```

#### Consuming in Widgets

```dart
class ThemeSelector extends ConsumerWidget {
  const ThemeSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(appConfigProvider);

    // Synchronous read; rebuilds ONLY when ui.themeMode changes!
    final themeMode = ref.watch(config.ui.themeMode.provider);

    return SegmentedButton<ThemeMode>(
      segments: const [
        ButtonSegment(value: ThemeMode.system, label: Text('System')),
        ButtonSegment(value: ThemeMode.light, label: Text('Light')),
        ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
      ],
      selected: {themeMode},
      // Direct mutation: updates RAM, syncs watching widgets immediately, debounces disk save
      onSelectionChanged: (selected) => config.ui.themeMode.value = selected.first,
    );
  }
}
```

---

## Additional information

- **Name Collision Tip:** If your codebase already defines a `Config` class, `typed_config` provides symmetrical aliases: `TypedConfig`, `TypedConfigBuilder`, and `TypedConfigEntry`.
- **Issues & Feedback:** File bug reports and feature requests on [GitHub Issues](https://github.com/jpangestu/typed_config/issues).
- **Contributing:** Pull requests are welcome! Please ensure all tests pass by running `dart test`.
