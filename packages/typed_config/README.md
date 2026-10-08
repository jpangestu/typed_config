# typed_config

A type-safe key-value store for application configurations with synchronous in-memory reads and disk persistence.

Manage and persist application settings (or preferences, or config, or whatever you wanna call it) with first-class support for primitives, enums, and custom types. Saved to disk as JSON with safe background saves, schema migrations, and file corruption recovery.

> **Using Riverpod?** Check out [`typed_config_riverpod`](https://pub.dev/packages/typed_config_riverpod) for reactive state notifiers and providers.

## Features

- **Strictly Type-Safe:** Guarantees non-null values with compile-time type checking.
- **Frame-0 Synchronous Reads:** In-memory cache allows instant synchronous reads with zero loading spinners or `FutureBuilder`.
- **Debounced Background Saves:** 300ms debounce prevents disk thrashing on slider scrubbing or rapid typing.
- **Hierarchical Dot-Namespacing:** Keys with dot notation (e.g. `'ui.colorScheme'`) stay flat in RAM for $O(1)$ lookups and automatically format into indented nested JSON on disk.
- **Schema Migrations:** Safely migrate configuration schemas sequentially between app releases ($v1 \rightarrow v2$).
- **Crash & Corruption Recovery:** Automatically quarantines malformed or damaged JSON files to `.corrupt` before restoring clean defaults.
- **Zero Framework Coupling:** Pure Dart library with no Flutter or UI dependencies; runs anywhere (Flutter, CLI tools, server apps).

## Getting started

Add `typed_config` to your `pubspec.yaml`:

```yaml
dependencies:
  typed_config: ^0.1.0
```

Import it in your Dart code:

```dart
import 'package:typed_config/typed_config.dart';
```

## Usage

### 1. Define your settings

Define settings as typed `ConfigEntry` objects. Grouping them inside an `abstract final class` is **optional but recommended** for clean namespacing and IDE autocompletion (e.g. typing `AppConfig.` reveals all settings):

```dart
enum ThemeMode { system, light, dark }

// Grouping configs inside an abstract final class is optional, but recommended
// for clean namespacing and IDE autocomplete (e.g. typing `AppConfig.` reveals all settings).
abstract final class AppConfig {
  static const volume = ConfigEntry<double>(key: 'volume', defaultValue: 0.8);

  static final themeMode = ConfigEntry<ThemeMode>(
    key: 'themeMode',
    defaultValue: ThemeMode.system,
    fromJson: (j) => ThemeMode.values.byName(j as String),
    toJson: (m) => m.name,
  );
}
```

> **Tip:** Keys with dots (like `'ui.themeMode'`) are automatically formatted as indented nested objects on disk.

### 2. Initialize once in `main()`

Load your configuration file asynchronously once at app startup. After this call, all reads anywhere in your app are 100% synchronous:

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final supportDir = await getApplicationSupportDirectory();
  final configFile = File('${supportDir.path}/config.json');

  final config = await Config.load(
    configFile,
    schemaVersion: 2,
    migrations: {
      // Migrate legacy flat keys to dot-notation in v2
      2: (raw) {
        if (raw.containsKey('theme')) raw['ui.colorScheme'] = raw.remove('theme');
        if (raw.containsKey('themeBrightness')) raw['ui.themeMode'] = raw.remove('themeBrightness');
      },
    },
  );

  runApp(MyApp(config: config));
}
```

### 3. Read and write settings

```dart
// Synchronous read (no await, no FutureBuilder, no spinners)
final currentVolume = config.get(AppConfig.volume);

// Update (immediate in memory, debounced in disk save)
config.set(AppConfig.volume, 0.95);

// Reset single setting to default value
config.reset(AppConfig.volume);

// Reset all settings to defaults
await config.resetAll();

// Listen to changes via Stream
config.watch(AppConfig.volume).listen((newVolume) {
  print('Volume changed: $newVolume');
});
```

## Additional information

- **Issues & Feedback:** File bug reports and feature requests on [GitHub Issues](https://github.com/jpangestu/typed_config/issues).
- **Contributing:** Pull requests are welcome! Please ensure all tests pass by running `dart test`.
