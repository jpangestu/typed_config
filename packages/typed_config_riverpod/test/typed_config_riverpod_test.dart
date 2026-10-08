import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';
import 'package:typed_config_riverpod/typed_config_riverpod.dart';

void main() {
  group('Riverpod Provider-per-Entry reactivity', () {
    const themeEntry = ConfigEntry<String>(key: 'theme', defaultValue: 'nord');
    const scaleEntry = ConfigEntry<double>(key: 'scale', defaultValue: 1.0);
    final themeSettingProvider = configEntryProviderFromEntry(themeEntry);
    final scaleSettingProvider = configEntryProviderFromEntry(scaleEntry);

    test('synchronous frame-0 read and fine-grained selector reactivity', () async {
      final config = Config.inMemory({'theme': 'nord', 'textScale': 1.0});

      final container = ProviderContainer(overrides: [configProvider.overrideWithValue(config)]);
      addTearDown(container.dispose);

      expect(container.read(themeSettingProvider), 'nord');
      expect(container.read(scaleSettingProvider), 1.0);

      final themeUpdates = <String>[];
      container.listen<String>(themeSettingProvider, (previous, next) => themeUpdates.add(next));

      config.set(scaleEntry, 1.5);
      await Future<void>.delayed(Duration.zero);
      expect(themeUpdates, isEmpty);

      config.set(themeEntry, 'graphite');
      await Future<void>.delayed(Duration.zero);
      expect(themeUpdates, ['graphite']);
    });

    test('updates state and underlying config via notifier set and reset', () {
      final config = Config.inMemory({'theme': 'nord'});

      final container = ProviderContainer(overrides: [configProvider.overrideWithValue(config)]);
      addTearDown(container.dispose);

      expect(container.read(themeSettingProvider), 'nord');

      container.read(themeSettingProvider.notifier).set('oceanic');
      expect(container.read(themeSettingProvider), 'oceanic');
      expect(config.get(themeEntry), 'oceanic');

      container.read(themeSettingProvider.notifier).reset();
      expect(container.read(themeSettingProvider), 'nord');
      expect(config.contains(themeEntry), isFalse);
    });

    test('synchronizes when resetAll emits wildcard change', () async {
      final config = Config.inMemory({'theme': 'custom_theme'});

      final container = ProviderContainer(overrides: [configProvider.overrideWithValue(config)]);
      addTearDown(container.dispose);

      expect(container.read(themeSettingProvider), 'custom_theme');

      await config.resetAll();
      await Future<void>.delayed(Duration.zero);

      expect(container.read(themeSettingProvider), 'nord');
    });

    test('configEntryProvider factory supports custom serializers', () {
      final customProvider = configEntryProvider<int>(key: 'custom_count', defaultValue: 10);

      final config = Config.inMemory({'custom_count': 25});
      final container = ProviderContainer(overrides: [configProvider.overrideWithValue(config)]);
      addTearDown(container.dispose);

      expect(container.read(customProvider), 25);

      container.read(customProvider.notifier).set(50);
      expect(container.read(customProvider), 50);
      expect(config.get(const ConfigEntry<int>(key: 'custom_count', defaultValue: 10)), 50);
    });
  });
}
