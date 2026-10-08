# typed_config_riverpod

Riverpod integration and fine-grained reactive providers for [`typed_config`](https://pub.dev/packages/typed_config).

Provides `ConfigNotifier`, `configProvider`, and `configEntryProvider` factories to seamlessly bind type-safe, disk-persisted settings into Flutter and Dart Riverpod applications.

## Features

- **Fine-Grained Selectivity:** Individual settings have their own providers; changing `audio.volume` will never trigger a rebuild in a widget watching `ui.themeMode`.
- **Frame-0 Synchronous Reads:** First build immediately has access to configuration without loading states or spinners.
- **Synchronized State:** Updating settings via `ref.read(provider.notifier).set(value)` immediately updates UI and triggers safe, debounced disk writes.
- **Auto-Syncing with File Watcher & Resets:** External file edits and global `resetAll()` calls automatically propagate to all active Riverpod notifiers.

## Getting started

Add both `typed_config` and `typed_config_riverpod` to your `pubspec.yaml`:

```yaml
dependencies:
  typed_config: ^0.1.0
  typed_config_riverpod: ^0.1.0
  riverpod: ^3.0.0
```

Import it in your Dart code:

```dart
import 'package:typed_config_riverpod/typed_config_riverpod.dart';
```

*(Note: `typed_config_riverpod` automatically re-exports `typed_config`, so you do not need to import both).*

## Usage

### 1. Define your settings & providers

Grouping providers inside an `abstract final class` is **optional but recommended** for clean namespacing and IDE autocompletion (e.g. typing `AppConfig.` reveals all providers):

```dart
abstract final class AppConfig {
  static final volumeProvider = configEntryProvider<double>(
    key: 'audio.volume',
    defaultValue: 0.8,
  );

  static final themeModeProvider = configEntryProvider<ThemeMode>(
    key: 'ui.themeMode',
    defaultValue: ThemeMode.system,
    fromJson: (j) => ThemeMode.values.byName(j as String),
    toJson: (m) => m.name,
  );
}
```

### 2. Supply the `Config` instance at app startup

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final supportDir = await getApplicationSupportDirectory();
  final configFile = File('${supportDir.path}/config.json');
  final config = await Config.load(configFile);

  runApp(
    ProviderScope(
      overrides: [
        configProvider.overrideWithValue(config),
      ],
      child: const MyApp(),
    ),
  );
}
```

### 3. Consume in widgets

```dart
class VolumeSlider extends ConsumerWidget {
  const VolumeSlider({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Reads synchronously on frame 0, rebuilds ONLY when volume changes
    final volume = ref.watch(AppConfig.volumeProvider);

    return Slider(
      value: volume,
      onChanged: (newVolume) {
        // Updates RAM immediately, debounces background disk save
        ref.read(AppConfig.volumeProvider.notifier).set(newVolume);
      },
    );
  }
}
```

### 4. Reset to default value

```dart
// Reverts volume back to 0.8 and persists
ref.read(AppConfig.volumeProvider.notifier).reset();
```

## Additional information

- **Core Engine:** For documentation on disk persistence, migrations, and corrupt recovery, see [`typed_config`](https://pub.dev/packages/typed_config).
- **Issues & Feedback:** File bug reports on [GitHub Issues](https://github.com/my_org/typed_config/issues).
