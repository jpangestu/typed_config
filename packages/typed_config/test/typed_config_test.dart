import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:typed_config/typed_config.dart';

void main() {
  group('ConfigEntry', () {
    const stringEntry = ConfigEntry<String>(key: 'testString', defaultValue: 'default_val');
    const doubleEntry = ConfigEntry<double>(key: 'testDouble', defaultValue: 1.0);
    const intEntry = ConfigEntry<int>(key: 'testInt', defaultValue: 10);
    const listEntry = ConfigEntry<List<String>>(key: 'testList', defaultValue: ['a', 'b']);

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
      final throwingEntry = ConfigEntry<String>(
        key: 'faulty',
        defaultValue: 'safe',
        toJson: (v) => throw Exception('serialization error'),
      );
      expect(throwingEntry.serialize('unsafe'), 'safe');
    });
  });

  group('Config In-Memory Engine', () {
    const themeEntry = ConfigEntry<String>(key: 'theme', defaultValue: 'nord');
    const scaleEntry = ConfigEntry<double>(key: 'scale', defaultValue: 1.0);
    const listEntry = ConfigEntry<List<String>>(key: 'genres', defaultValue: ['classical']);
    const flagEntry = ConfigEntry<bool>(key: 'adaptiveBg', defaultValue: false);

    test('reads default values when cache is empty', () {
      final config = Config.inMemory();
      expect(config.get(themeEntry), 'nord');
      expect(config.contains(themeEntry), isFalse);
    });

    test('updates values in memory and notifies stream', () async {
      final config = Config.inMemory();
      final themeEvents = <String>[];
      final sub = config.watch<String>(themeEntry).listen((e) => themeEvents.add(e));
      addTearDown(sub.cancel);

      config.set(themeEntry, 'graphite');
      expect(config.get(themeEntry), 'graphite');
      expect(config.contains(themeEntry), isTrue);

      await Future<void>.delayed(Duration.zero);
      expect(themeEvents, ['graphite']);
    });

    test('defensively wraps collections in unmodifiable views', () {
      final config = Config.inMemory();
      config.set(listEntry, ['pop', 'rock']);

      final readList = config.get(listEntry);
      expect(readList, ['pop', 'rock']);
      expect(() => readList.add('jazz'), throwsUnsupportedError);
    });

    test('reset reverts entry to default and notifies stream', () async {
      final config = Config.inMemory({'theme': 'graphite'});
      final themeEvents = <String>[];
      final sub = config.watch<String>(themeEntry).listen((e) => themeEvents.add(e));
      addTearDown(sub.cancel);

      expect(config.contains(themeEntry), isTrue);
      expect(config.get(themeEntry), 'graphite');

      config.reset(themeEntry);

      expect(config.contains(themeEntry), isFalse);
      expect(config.get(themeEntry), 'nord');

      await Future<void>.delayed(Duration.zero);
      expect(themeEvents, ['nord']);
    });

    test('watch(entry) only fires for targeted entry changes', () async {
      final config = Config.inMemory();
      final themeEvents = <String>[];
      final scaleEvents = <double>[];

      final sub1 = config.watch<String>(themeEntry).listen((e) => themeEvents.add(e));
      final sub2 = config.watch<double>(scaleEntry).listen((e) => scaleEvents.add(e));
      addTearDown(sub1.cancel);
      addTearDown(sub2.cancel);

      config.set(scaleEntry, 1.25);
      await Future<void>.delayed(Duration.zero);

      expect(themeEvents, isEmpty);
      expect(scaleEvents, [1.25]);

      config.set(themeEntry, 'ocean');
      await Future<void>.delayed(Duration.zero);

      expect(themeEvents, ['ocean']);
      expect(scaleEvents, [1.25]);
    });

    test('resetAll clears cached overrides and notifies wildcard', () async {
      final config = Config.inMemory({'theme': 'graphite', 'adaptiveBg': true});

      expect(config.get(themeEntry), 'graphite');
      expect(config.get(flagEntry), isTrue);

      await config.resetAll();

      expect(config.get(themeEntry), 'nord');
      expect(config.get(flagEntry), isFalse);
    });
  });

  group('Config File Persistence & Watcher', () {
    late Directory tempDir;
    late File configFile;
    const themeEntry = ConfigEntry<String>(key: 'theme', defaultValue: 'nord');

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
      final config = await Config.load(deepFile);
      addTearDown(config.dispose);

      expect(deepFile.existsSync(), isTrue);
      final content = jsonDecode(await deepFile.readAsString());
      expect(content, isA<Map>());
    });

    test('debounces save and persists upon flush', () async {
      final config = await Config.load(configFile);
      addTearDown(config.dispose);

      config.set(themeEntry, 'graphite');

      // Flush debounced save to disk
      await config.flush();

      expect(configFile.existsSync(), isTrue);
      final saved = jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
      expect(saved['theme'], 'graphite');
    });

    test('synchronously saves dirty changes when disposed before debounce finishes', () async {
      final config = await Config.load(configFile);

      // Arm debounce timer
      config.set(themeEntry, 'midnight_blue');

      // Dispose immediately before the 300ms timer fires
      config.dispose();

      expect(configFile.existsSync(), isTrue);
      final saved = jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
      expect(saved['theme'], 'midnight_blue');
    });

    test('coalesces rapid concurrent flushes safely without disk corruption', () async {
      final config = await Config.load(configFile);
      addTearDown(config.dispose);

      await Future.wait([
        () async {
          config.set(themeEntry, 'async_1');
          await config.flush();
        }(),
        () async {
          config.set(themeEntry, 'async_2');
          await config.flush();
        }(),
        () async {
          config.set(themeEntry, 'async_3');
          await config.flush();
        }(),
      ]);

      expect(configFile.existsSync(), isTrue);
      final content = jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
      expect(content['theme'], isNotNull);
    });

    test('recovers safely from corrupted JSON file and quarantines it', () async {
      await configFile.writeAsString('NOT VALID JSON {{{');

      final config = await Config.load(configFile);
      addTearDown(config.dispose);

      expect(config.get(themeEntry), 'nord');

      final corruptFile = File('${configFile.path}.corrupt');
      expect(corruptFile.existsSync(), isTrue);
      expect(await corruptFile.readAsString(), 'NOT VALID JSON {{{');
    });

    test('migrates schema version and updates keys seamlessly', () async {
      await configFile.writeAsString(jsonEncode({'theme': 'dracula', 'themeBrightness': 'dark'}));

      final config = await Config.load(
        configFile,
        schemaVersion: 2,
        migrations: {
          2: (raw) {
            if (raw.containsKey('theme')) {
              raw['colorScheme'] = raw.remove('theme');
            }
            if (raw.containsKey('themeBrightness')) {
              raw['themeMode'] = raw.remove('themeBrightness');
            }
          },
        },
      );
      addTearDown(config.dispose);

      const newSchemeEntry = ConfigEntry<String>(key: 'colorScheme', defaultValue: 'nord');
      const newModeEntry = ConfigEntry<String>(key: 'themeMode', defaultValue: 'system');

      expect(config.get(newSchemeEntry), 'dracula');
      expect(config.get(newModeEntry), 'dark');

      final onDisk = jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
      expect(onDisk['schemaVersion'], 2);
      expect(onDisk['colorScheme'], 'dracula');
      expect(onDisk['themeMode'], 'dark');
    });

    test('chains multiple migrations in sequential order', () async {
      await configFile.writeAsString(jsonEncode({'schemaVersion': 1, 'val': 10}));

      final config = await Config.load(
        configFile,
        schemaVersion: 3,
        migrations: {
          2: (raw) => raw['val'] = (raw['val'] as int) + 5,
          3: (raw) => raw['val'] = (raw['val'] as int) * 2,
        },
      );
      addTearDown(config.dispose);

      const valEntry = ConfigEntry<int>(key: 'val', defaultValue: 0);
      expect(config.get(valEntry), 30);

      final onDisk = jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
      expect(onDisk['schemaVersion'], 3);
      expect(onDisk['val'], 30);
    });

    test('serializes dot-separated keys into indented nested objects on disk', () async {
      final config = await Config.load(configFile);
      addTearDown(config.dispose);

      const schemeEntry = ConfigEntry<String>(key: 'ui.colorScheme', defaultValue: 'nord');
      const blurEntry = ConfigEntry<double>(key: 'ui.adaptiveBg.blur', defaultValue: 20.0);

      config.set(schemeEntry, 'graphite');
      config.set(blurEntry, 35.0);
      await config.flush();

      final rawContent = await configFile.readAsString();
      expect(rawContent.contains('  "ui": {'), isTrue);
      expect(rawContent.contains('    "colorScheme": "graphite"'), isTrue);
      expect(rawContent.contains('    "adaptiveBg": {'), isTrue);
      expect(rawContent.contains('      "blur": 35.0'), isTrue);

      final parsed = jsonDecode(rawContent) as Map<String, dynamic>;
      expect((parsed['ui'] as Map)['colorScheme'], 'graphite');
      expect(((parsed['ui'] as Map)['adaptiveBg'] as Map)['blur'], 35.0);
    });

    test('flattens nested objects on load for synchronous reads', () async {
      await configFile.writeAsString(
        jsonEncode({
          'schemaVersion': 2,
          'ui': {
            'colorScheme': 'solarized',
            'adaptiveBg': {'blur': 50.0},
          },
        }),
      );

      final config = await Config.load(configFile);
      addTearDown(config.dispose);

      const schemeEntry = ConfigEntry<String>(key: 'ui.colorScheme', defaultValue: 'nord');
      const blurEntry = ConfigEntry<double>(key: 'ui.adaptiveBg.blur', defaultValue: 20.0);

      expect(config.get(schemeEntry), 'solarized');
      expect(config.get(blurEntry), 50.0);
    });

    test('guarantees schemaVersion is pinned to the very top of disk output', () async {
      final unordered = <String, dynamic>{
        'audio.volume': 0.8,
        'ui.colorScheme': 'nord',
        Config.schemaVersionKey: 2,
      };

      final config = Config(configFile, unordered);
      addTearDown(config.dispose);
      await config.flush();

      final rawContent = await configFile.readAsString();
      final lines = rawContent.split('\n').map((l) => l.trim()).toList();

      expect(lines[1], '"schemaVersion": 2,');
    });

    test('reloads state when config file is modified externally', () async {
      final config = await Config.load(configFile);
      addTearDown(config.dispose);

      final reloadedEvents = <String>[];
      final sub = config.watch<String>(themeEntry).listen((e) => reloadedEvents.add(e));
      addTearDown(sub.cancel);

      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await configFile.writeAsString(jsonEncode({'theme': 'forest'}));

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(config.get(themeEntry), 'forest');
    });
  });
}
