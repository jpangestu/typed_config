# typed_config

Manage and persist application configs (or settings, or preferences, or whatever you wanna call it) with first-class support for built-in types, enums, and custom models. Saved to disk as JSON.

## Features

- **Type-Safe:** Compile-time validation prevents type mismatches and eliminates manual casting.
- **Synchronous Reads:** In-memory cache allows instant synchronous reads.
- **Debounced Saves:** Non-blocking, debounced file writes prevent disk thrashing during rapid state updates.
- **Domain Groups & Auto-Namespacing:** Organize configs into sub-group (e.g., AudioSettings, UiSettings); keys are automatically namespaced (`['audio', 'volume']`) and serialize into indented nested JSON on disk.
- **Schema Migrations:** Safely migrate configuration schemas sequentially between app releases ($v1 \rightarrow v2$).
- **Crash & Corruption Recovery:** Automatically quarantines malformed or damaged JSON files with a timestamp (e.g., `.<timestamp>.corrupt`) before restoring clean defaults.
- **Zero Framework Coupling:** Pure Dart library with no Flutter or UI dependencies.

## Usage

### 1. Define your config

Create your configuration schema by extending `Config`. You can define individual configs or organize them into domain-driven groups using `builder.group()`:

```dart
enum ThemeMode { system, light, dark }

// Uses Dart 3.13+ Primary Constructors (see below for Dart 3.2 – 3.12 syntax).

// Main application configuration
final class AppConfig(super.builder) extends Config {
  final language = builder.define('language', 'en');
  final autoCheckUpdates = builder.define('autoCheckUpdates', true);

  // If you want to organize your config into groups
  final ui = builder.group('ui', UiSettings.new);
}

// Grouped config
final class UiSettings(super.builder) extends Config {
  final themeMode = builder.defineEnum('themeMode', ThemeMode.system, values: ThemeMode.values);
  final compactMode = builder.define('compactMode', false);
  final fontScale = builder.define('fontScale', 1.0);
}
```

> **Tip:** `builder.group('ui', UiSettings.new)` automatically prefixes child keys as `['ui', 'themeMode']`, formatting into indented nested objects on disk.

<details>
<summary><b>Using Dart 3.2 – 3.12 (without Primary Constructors)?</b></summary>

In Dart versions prior to 3.13, because standard field initializers cannot reference `builder` before construction, choose between:

#### Option A: Constructor Initialization (Eager)

Initializes all entries eagerly during object creation using standard constructor initializer lists:

```dart
// Main application config
final class AppConfig extends Config {
  final ConfigEntry<String> language;
  final ConfigEntry<bool> autoCheckUpdates;
  final UiSettings ui;

  AppConfig(super.builder)
      : language = builder.define('language', 'en'),
        autoCheckUpdates = builder.define('autoCheckUpdates', true),
        ui = builder.group('ui', UiSettings.new);
}

// Grouped config
final class UiSettings extends Config {
  final ConfigEntry<ThemeMode> themeMode;
  final ConfigEntry<bool> compactMode;
  final ConfigEntry<double> fontScale;

  UiSettings(super.builder)
      : themeMode = builder.defineEnum('themeMode', ThemeMode.system, values: ThemeMode.values),
        compactMode = builder.define('compactMode', false),
        fontScale = builder.define('fontScale', 1.0);
}
```

#### Option B: Inline Field Initialization (Lazy)

Initializes entries lazily on first access using `late final`:

```dart
// Main application config
final class AppConfig extends Config {
  AppConfig(super.builder);

  late final language = builder.define('language', 'en');
  late final autoCheckUpdates = builder.define('autoCheckUpdates', true);
  late final ui = builder.group('ui', UiSettings.new);
}

// Grouped config
final class UiSettings extends Config {
  UiSettings(super.builder);

  late final themeMode = builder.defineEnum('themeMode', ThemeMode.system, values: ThemeMode.values);
  late final compactMode = builder.define('compactMode', false);
  late final fontScale = builder.define('fontScale', 1.0);
}
```
</details>

### 2. Initialize once in `main()`

Load your configuration file asynchronously once at app startup via constructor tear-off (`AppConfig.new`). After this call, all reads anywhere in your app are 100% synchronous:

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final supportDir = await getApplicationSupportDirectory();
  final configFile = File('${supportDir.path}/config.json');

  final config = await Config.initialize(
    configFile: configFile,
    create: AppConfig.new,
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

// Reset all configs to defaults (preserves schemaVersion)
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
    final config = Config.inMemory(create: AppConfig.new);

    expect(config.ui.themeMode.value, ThemeMode.system);
    config.ui.themeMode.value = ThemeMode.dark;
    expect(config.ui.themeMode.value, ThemeMode.dark);
  });
}
```

### 5. Schema Migrations

> **Rule of Thumb:**
> * **Adding a new setting?** You do **not** need a migration or version bump. Absent keys automatically return their `defaultValue`.
> * **Renaming, reshaping, or converting types?** Increment `schemaVersion` and supply sequential `ConfigMigrator` handlers ($v1 \rightarrow v2 \rightarrow v3$):

```dart
final config = await Config.initialize(
  configFile: configFile,
  create: AppConfig.new,
  schemaVersion: 2,
  migrations: {
    2: (m) {
      // Move old key to a new prefix group
      m.rename(['theme'], ['ui', 'themeMode']);

      // Transform existing values or types (e.g. 0..100 to 0.0..1.0)
      m.transform(['audio', 'volume'], (v) => (v as num) / 100.0);

      // Purge a retired feature key
      m.remove(['legacy_telemetry']);
    },
  },
);
```

---

## Integrations

Because typed_config is pure Dart, you can easily bridge it to Flutter or your favorite state management solution.

<details>
<summary><b>Riverpod Integration</b></summary>

You can bridge typed_config into Riverpod with this lightweight extension, allowing widgets to watch individual entries without rebuilding on unrelated config changes:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:typed_config/typed_config.dart';

final _entryProviderCache = Expando<Object>();

/// Extension to add a reactive [provider] getter to [ConfigEntry].
extension ConfigEntryRiverpodX<T> on ConfigEntry<T> {
  Provider<T> get provider {
    final cached = _entryProviderCache[this];
    if (cached != null) return cached as Provider<T>;

    final created = Provider<T>((ref) {
      final sub = changes.listen((_) => ref.invalidateSelf());
      ref.onDispose(sub.cancel);
      return value;
    });
    _entryProviderCache[this] = created;
    return created;
  }
}

/// Provider for your main configuration class. Override this in [ProviderScope].
final appConfigProvider = Provider<AppConfig>((ref) {
  throw UnimplementedError('appConfigProvider must be overridden in ProviderScope');
});
```

#### Setup in `main.dart`

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final config = await Config.initialize(
    configFile: File('path/to/config.json'),
    create: AppConfig.new,
  );

  runApp(
    ProviderScope(
      overrides: [
        appConfigProvider.overrideWith((ref) {
          ref.onDispose(config.dispose);
          return config;
        }),
      ],
      child: const MyApp(),
    ),
  );
}
```

#### Usage in Widgets

```dart
class ThemeSelector extends ConsumerWidget {
  const ThemeSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appConfig = ref.watch(appConfigProvider);

    // Notice the usage of .provider here
    final themeMode = ref.watch(appConfig.ui.themeMode.provider);

    return SegmentedButton<ThemeMode>(
      segments: const [
        ButtonSegment(value: ThemeMode.system, label: Text('System')),
        ButtonSegment(value: ThemeMode.light, label: Text('Light')),
        ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
      ],
      selected: {themeMode},
      onSelectionChanged: (selected) => appConfig.ui.themeMode.value = selected.first,
    );
  }
}
```

</details>

---

## Additional information

- **Issues & Feedback:** File bug reports and feature requests on [GitHub Issues](https://github.com/jpangestu/typed_config/issues).