import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:typed_config/src/config_builder.dart';
import 'package:typed_config/src/config_engine.dart';
import 'package:typed_config/src/typed_config.dart';

final class NestedUiConfig extends TypedConfig {
  final ConfigEntry<String> theme;
  final ConfigEntry<double> scale;

  NestedUiConfig(super.builder)
      : theme = builder.define('theme', 'system'),
        scale = builder.define('scale', 1.0);
}

final class WatcherTestConfig extends TypedConfig {
  final ConfigEntry<String> title;
  final ConfigEntry<int> count;
  final NestedUiConfig ui;

  WatcherTestConfig(super.builder)
      : title = builder.define('title', 'InitialTitle'),
        count = builder.define('count', 0),
        ui = builder.group('ui', NestedUiConfig.new);
}

void main() {
  group('diffKeyPaths', () {
    test('returns empty list when maps are identical', () {
      final map1 = {
        'a': 1,
        'b': {'c': 'hello'},
        'd': [1, 2],
      };
      final map2 = {
        'a': 1,
        'b': {'c': 'hello'},
        'd': [1, 2],
      };

      expect(diffKeyPaths(map1, map2), isEmpty);
    });

    test('detects added, removed, and updated keys', () {
      final oldMap = {
        'stay': 1,
        'removed': 2,
        'updated': 'old',
      };
      final newMap = {
        'stay': 1,
        'added': 3,
        'updated': 'new',
      };

      final diff = diffKeyPaths(oldMap, newMap);
      expect(
        diff,
        unorderedEquals([
          ['removed'],
          ['added'],
          ['updated'],
        ]),
      );
    });

    test('detects nested changes without notifying unaffected siblings', () {
      final oldMap = {
        'ui': {
          'theme': 'light',
          'scale': 1.0,
        },
      };
      final newMap = {
        'ui': {
          'theme': 'dark',
          'scale': 1.0,
        },
      };

      final diff = diffKeyPaths(oldMap, newMap);
      expect(
          diff,
          equals([
            ['ui', 'theme']
          ]));
    });

    test('handles addition and removal of entire sub-maps', () {
      final oldMap = <String, dynamic>{};
      final newMap = {
        'ui': {'theme': 'dark'},
      };

      final diff = diffKeyPaths(oldMap, newMap);
      expect(
          diff,
          equals([
            ['ui']
          ]));

      final reverseDiff = diffKeyPaths(newMap, oldMap);
      expect(
          reverseDiff,
          equals([
            ['ui']
          ]));
    });
  });

  group('watchConfigFile', () {
    late Directory tempDir;
    late File configFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('typed_config_watch_test_');
      configFile = File('${tempDir.path}/config.json');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('reloads config and emits reactive stream events on external file write', () async {
      final config = await TypedConfig.initialize(
        configFile: configFile,
        create: WatcherTestConfig.new,
        watchConfigFile: true,
      );

      final titleUpdates = <String>[];
      final titleSub = config.title.changes.listen(titleUpdates.add);

      final themeUpdates = <String>[];
      final themeSub = config.ui.theme.changes.listen(themeUpdates.add);

      // Simulate external editor writing new content to disk
      await configFile.writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'title': 'ExternallyModified',
          'ui': {'theme': 'dark'},
        }),
      );

      // Allow file event and debounce timer to fire
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(config.title.value, equals('ExternallyModified'));
      expect(config.ui.theme.value, equals('dark'));
      expect(titleUpdates, equals(['ExternallyModified']));
      expect(themeUpdates, equals(['dark']));

      await titleSub.cancel();
      await themeSub.cancel();
      config.dispose();
    });

    test('does not quarantine or wipe memory when external JSON has syntax error', () async {
      Object? capturedError;

      final config = await TypedConfig.initialize(
        configFile: configFile,
        create: WatcherTestConfig.new,
        watchConfigFile: true,
        onError: (err, _) => capturedError = err,
      );

      config.title.value = 'ValidState';
      await config.flush();

      // Simulate user typing invalid JSON in an editor
      await configFile.writeAsString('{ broken: json,');

      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Error reported, but memory state is retained
      expect(capturedError, isA<FormatException>());
      expect(config.title.value, equals('ValidState'));

      // File was NOT renamed to .corrupt during live watch
      final corruptFiles = tempDir.listSync().where((f) => f.path.endsWith('.corrupt'));
      expect(corruptFiles, isEmpty);

      config.dispose();
    });

    test('retains memory and logs error when external JSON is an array', () async {
      Object? capturedError;

      final config = await TypedConfig.initialize(
        configFile: configFile,
        create: WatcherTestConfig.new,
        watchConfigFile: true,
        onError: (err, _) => capturedError = err,
      );

      await configFile.writeAsString('[1, 2, 3]');

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(capturedError, isA<FormatException>());
      expect(config.title.value, equals('InitialTitle'));

      config.dispose();
    });

    test('disk wins over pending debounced in-memory write', () async {
      final config = await TypedConfig.initialize(
        configFile: configFile,
        create: WatcherTestConfig.new,
        debounceDuration: const Duration(seconds: 5), // Pending debounced save
        watchConfigFile: true,
      );

      // Local change in memory with long debounce
      config.title.value = 'LocalUnsaved';

      // External file save
      await configFile.writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'title': 'DiskVersionWins',
        }),
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Disk version wins and overwrites local in-memory change
      expect(config.title.value, equals('DiskVersionWins'));

      config.dispose();
    });

    test('self-writes via flush do not trigger redundant reload loops', () async {
      var logCount = 0;

      final config = await TypedConfig.initialize(
        configFile: configFile,
        create: WatcherTestConfig.new,
        watchConfigFile: true,
        onLog: (msg) {
          if (msg.contains('Reloaded configuration from disk')) {
            logCount++;
          }
        },
      );

      // Internal write and flush
      config.title.value = 'InternalFlush';
      await config.flush();

      // Wait longer than reload debounce
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Echo prevention: Should not reload what we just wrote
      expect(logCount, equals(0));
      expect(config.title.value, equals('InternalFlush'));

      config.dispose();
    });
  });
}
