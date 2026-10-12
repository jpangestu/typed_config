import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:typed_config/typed_config.dart';

enum ThemeMode { system, light, dark }

class AudioSettings(ConfigBuilder builder) {
  final volume = builder.define('volume', 0.8);
  final muted = builder.define('muted', false);
}

class UiSettings(ConfigBuilder builder) {
  final themeMode = builder.defineEnum('themeMode', ThemeMode.system, values: ThemeMode.values);
  final scale = builder.define('scale', 1.0);
}

class TestConfig(ConfigBuilder builder) extends Config {
  final audio = AudioSettings(builder.withPrefix('audio'));
  final ui = UiSettings(builder.withPrefix('ui'));
  final tags = builder.defineList('tags', ['default']);
}

class MigrationConfig(ConfigBuilder builder) extends Config {
  final val = builder.define('val', 0);
}

void main() {
  group('ConfigEntry Parsing & Serialization', () {
    late Config config;
    late ConfigEntry<String> stringEntry;
    late ConfigEntry<double> doubleEntry;
    late ConfigEntry<int> intEntry;
    late ConfigEntry<List<String>> listEntry;

    setUp(() {
      config = Config.inMemory(Config.new);
      stringEntry = config.builder.define('testString', 'default_val');
      doubleEntry = config.builder.define('testDouble', 1.0);
      intEntry = config.builder.define('testInt', 10);
      listEntry = config.builder.defineList('testList', ['a', 'b']);
    });

    test('returns defaultValue when parsing null or invalid type', () {
      expect(stringEntry.parse(null), 'default_val');
      expect(stringEntry.parse(123), 'default_val');
      expect(stringEntry.parse(true), 'default_val');
      expect(stringEntry.parse('custom'), 'custom');
    });

    test('coerces num to double safely', () {
      expect(doubleEntry.parse(2), 2.0);
      expect(doubleEntry.parse(2.5), 2.5);
      expect(doubleEntry.parse('not_num'), 1.0);
    });

    test('coerces num to int safely', () {
      expect(intEntry.parse(42.9), 42);
      expect(intEntry.parse(50), 50);
      expect(intEntry.parse('not_num'), 10);
    });

    test('coerces dynamic list to unmodifiable List<String>', () {
      final parsed = listEntry.parse(['x', 'y', 123]);
      expect(parsed, ['x', 'y']);
      expect(() => parsed.add('z'), throwsUnsupportedError);
      expect(listEntry.parse('not_a_list'), ['a', 'b']);
    });

    test('safely handles throwing toJson serializer', () {
      final throwingEntry = config.builder.define<String>(
        'faulty',
        'safe',
        toJson: (v) => throw Exception('serialization error'),
      );
      expect(throwingEntry.serialize('unsafe'), 'safe');
    });
  });

  group('Config In-Memory Engine & Direct Handle Usage', () {
    test('reads default values when cache is empty', () {
      final config = Config.inMemory(TestConfig.new);
      expect(config.audio.volume.value, 0.8);
      expect(config.audio.volume.isModified, isFalse);
    });

    test('updates values in memory immediately and notifies stream', () async {
      final config = Config.inMemory(TestConfig.new);
      final events = <double>[];
      final sub = config.audio.volume.changes.listen(events.add);
      addTearDown(sub.cancel);

      config.audio.volume.value = 0.5;
      expect(config.audio.volume.value, 0.5);
      expect(config.audio.volume.isModified, isTrue);

      await Future<void>.delayed(Duration.zero);
      expect(events, [0.5]);
    });

    test('supports reset() and isModified flag', () async {
      final config = Config.inMemory(TestConfig.new);
      final events = <double>[];
      final sub = config.audio.volume.changes.listen(events.add);
      addTearDown(sub.cancel);

      config.audio.volume.value = 0.2;
      expect(config.audio.volume.value, 0.2);
      expect(config.audio.volume.isModified, isTrue);
      await Future<void>.delayed(Duration.zero);

      config.audio.volume.reset();
      expect(config.audio.volume.value, 0.8);
      expect(config.audio.volume.isModified, isFalse);
      await Future<void>.delayed(Duration.zero);

      expect(events, [0.2, 0.8]);
    });

    test('defensively wraps collections in unmodifiable views', () {
      final config = Config.inMemory(TestConfig.new);
      config.tags.value = ['pop', 'rock'];

      final readList = config.tags.value;
      expect(readList, ['pop', 'rock']);
      expect(() => readList.add('jazz'), throwsUnsupportedError);
    });

    test('fine-grained reactivity: changes only fires for targeted entry', () async {
      final config = Config.inMemory(TestConfig.new);
      final volumeEvents = <double>[];
      final themeEvents = <ThemeMode>[];

      final sub1 = config.audio.volume.changes.listen(volumeEvents.add);
      final sub2 = config.ui.themeMode.changes.listen(themeEvents.add);
      addTearDown(sub1.cancel);
      addTearDown(sub2.cancel);

      // Mutate volume only
      config.audio.volume.value = 0.95;
      await Future<void>.delayed(Duration.zero);

      expect(volumeEvents, [0.95]);
      expect(themeEvents, isEmpty);

      // Mutate theme only
      config.ui.themeMode.value = ThemeMode.dark;
      await Future<void>.delayed(Duration.zero);

      expect(volumeEvents, [0.95]);
      expect(themeEvents, [ThemeMode.dark]);
    });

    test('resetAll clears cached overrides and notifies all entries', () async {
      final config = Config.inMemory(TestConfig.new, {'audio.volume': 0.1, 'ui.scale': 1.5});

      expect(config.audio.volume.value, 0.1);
      expect(config.ui.scale.value, 1.5);

      await config.resetAll();

      expect(config.audio.volume.value, 0.8);
      expect(config.ui.scale.value, 1.0);
    });

    test('serializes enums cleanly with entryEnum', () {
      final config = Config.inMemory(TestConfig.new);
      expect(config.ui.themeMode.value, ThemeMode.system);

      config.ui.themeMode.value = ThemeMode.dark;
      expect(config.ui.themeMode.value, ThemeMode.dark);
      expect(config.cache['ui.themeMode'], 'dark');
    });
  });

  group('Config File Persistence & Watcher', () {
    late Directory tempDir;
    late File configFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('typed_config_test_');
      configFile = File('${tempDir.path}/config.json');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('creates default file and missing parent directories when file does not exist', () async {
      final deepFile = File('${tempDir.path}/nested/subdir/deep/config.json');
      final config = await Config.initialize(TestConfig.new, deepFile);
      addTearDown(config.dispose);

      expect(deepFile.existsSync(), isTrue);
      final content = jsonDecode(await deepFile.readAsString());
      expect(content, isA<Map>());
    });

    test('debounces save and persists upon flush', () async {
      final config = await Config.initialize(TestConfig.new, configFile);
      addTearDown(config.dispose);

      config.audio.volume.value = 0.35;

      // Flush debounced save to disk
      await config.flush();

      expect(configFile.existsSync(), isTrue);
      final saved = jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
      expect((saved['audio'] as Map)['volume'], 0.35);
    });

    test('synchronously saves dirty changes when disposed before debounce finishes', () async {
      final config = await Config.initialize(TestConfig.new, configFile);

      // Arm debounce timer
      config.audio.volume.value = 0.42;

      // Dispose immediately before the 300ms timer fires
      config.dispose();

      expect(configFile.existsSync(), isTrue);
      final saved = jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
      expect((saved['audio'] as Map)['volume'], 0.42);
    });

    test('coalesces rapid concurrent flushes safely without disk corruption', () async {
      final config = await Config.initialize(TestConfig.new, configFile);
      addTearDown(config.dispose);

      await Future.wait([
        () async {
          config.audio.volume.value = 0.1;
          await config.flush();
        }(),
        () async {
          config.audio.volume.value = 0.2;
          await config.flush();
        }(),
        () async {
          config.audio.volume.value = 0.3;
          await config.flush();
        }(),
      ]);

      expect(configFile.existsSync(), isTrue);
      final content = jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
      expect(content['audio'], isNotNull);
    });

    test('recovers safely from corrupted JSON file and quarantines it', () async {
      await configFile.writeAsString('NOT VALID JSON {{{');

      final config = await Config.initialize(TestConfig.new, configFile);
      addTearDown(config.dispose);

      expect(config.audio.volume.value, 0.8);

      final corruptFile = File('${configFile.path}.corrupt');
      expect(corruptFile.existsSync(), isTrue);
      expect(await corruptFile.readAsString(), 'NOT VALID JSON {{{');
    });

    test('migrates schema version and updates keys seamlessly', () async {
      await configFile.writeAsString(jsonEncode({'theme': 'dark', 'vol': 0.6}));

      final config = await Config.initialize(
        TestConfig.new,
        configFile,
        schemaVersion: 2,
        migrations: {
          2: (raw) {
            if (raw.containsKey('theme')) {
              raw['ui.themeMode'] = raw.remove('theme');
            }
            if (raw.containsKey('vol')) {
              raw['audio.volume'] = raw.remove('vol');
            }
          },
        },
      );
      addTearDown(config.dispose);

      expect(config.ui.themeMode.value, ThemeMode.dark);
      expect(config.audio.volume.value, 0.6);

      final onDisk = jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
      expect(onDisk['schemaVersion'], 2);
      expect((onDisk['ui'] as Map)['themeMode'], 'dark');
      expect((onDisk['audio'] as Map)['volume'], 0.6);
    });

    test('chains multiple migrations in sequential order', () async {
      await configFile.writeAsString(jsonEncode({'schemaVersion': 1, 'val': 10}));

      final config = await Config.initialize(
        MigrationConfig.new,
        configFile,
        schemaVersion: 3,
        migrations: {
          2: (raw) => raw['val'] = (raw['val'] as int) + 5,
          3: (raw) => raw['val'] = (raw['val'] as int) * 2,
        },
      );
      addTearDown(config.dispose);

      expect(config.val.value, 30);

      final onDisk = jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
      expect(onDisk['schemaVersion'], 3);
      expect(onDisk['val'], 30);
    });

    test('quarantines file and falls back to defaults when a migration throws', () async {
      await configFile.writeAsString(jsonEncode({'schemaVersion': 1, 'val': 10}));
      final logs = <String>[];

      final config = await Config.initialize(
        MigrationConfig.new,
        configFile,
        schemaVersion: 2,
        onLog: logs.add,
        migrations: {2: (_) => throw Exception('Intentional migration failure')},
      );
      addTearDown(config.dispose);

      expect(config.val.value, 0); // fallback default
      expect(logs.any((l) => l.contains('Migration to schema version v2 failed')), isTrue);
      expect(File('${configFile.path}.corrupt').existsSync(), isTrue);
    });

    test('serializes dot-separated keys into indented nested objects on disk', () async {
      final config = await Config.initialize(TestConfig.new, configFile);
      addTearDown(config.dispose);

      config.audio.volume.value = 0.75;
      config.ui.scale.value = 1.25;
      await config.flush();

      final rawContent = await configFile.readAsString();
      expect(rawContent.contains('  "audio": {'), isTrue);
      expect(rawContent.contains('    "volume": 0.75'), isTrue);
      expect(rawContent.contains('  "ui": {'), isTrue);
      expect(rawContent.contains('    "scale": 1.25'), isTrue);

      final parsed = jsonDecode(rawContent) as Map<String, dynamic>;
      expect((parsed['audio'] as Map)['volume'], 0.75);
      expect((parsed['ui'] as Map)['scale'], 1.25);
    });

    test('flattens nested objects on load for synchronous reads', () async {
      await configFile.writeAsString(
        jsonEncode({
          'schemaVersion': 2,
          'audio': {'volume': 0.65},
          'ui': {'scale': 2.0},
        }),
      );

      final config = await Config.initialize(TestConfig.new, configFile);
      addTearDown(config.dispose);

      expect(config.audio.volume.value, 0.65);
      expect(config.ui.scale.value, 2.0);
    });

    test('guarantees schemaVersion is pinned to the very top of disk output', () async {
      final unordered = <String, dynamic>{
        'audio.volume': 0.8,
        'ui.scale': 1.0,
        Config.schemaVersionKey: 2,
      };

      final config = Config.inMemory(TestConfig.new, unordered);
      addTearDown(config.dispose);

      final unflattened = config.toJson();
      expect(unflattened.keys.first, Config.schemaVersionKey);
    });

    test('reloads state when config file is modified externally', () async {
      final config = await Config.initialize(TestConfig.new, configFile);
      addTearDown(config.dispose);

      final reloadedEvents = <double>[];
      final sub = config.audio.volume.changes.listen(reloadedEvents.add);
      addTearDown(sub.cancel);

      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await configFile.writeAsString(
        jsonEncode({
          'audio': {'volume': 0.15},
        }),
      );

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(config.audio.volume.value, 0.15);
    });
  });

  group('Typed* Aliases Symmetrical Compatibility', () {
    test('works with TypedConfig, TypedConfigBuilder, and TypedConfigEntry', () {
      final config = TypedConfig.inMemory((TypedConfigBuilder builder) {
        return _AliasedConfig(builder);
      });

      expect(config.setting.value, 'hello');
      config.setting.value = 'world';
      expect(config.setting.value, 'world');
    });
  });
}

class _AliasedConfig(TypedConfigBuilder builder) extends TypedConfig {
  final TypedConfigEntry<String> setting = builder.define('setting', 'hello');
}
