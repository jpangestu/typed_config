import 'dart:async';

import 'package:test/test.dart';
import 'package:typed_config/src/config_engine.dart';

void main() {
  group('ConfigEngine', () {
    group('read', () {
      test('returns null for empty cache or non-existent key', () {
        final engine = ConfigEngine(inMemoryCache: {});
        expect(engine.read(['missing']), isNull);
        expect(engine.read(['nested', 'missing']), isNull);
      });

      test('returns value for top-level key', () {
        final engine = ConfigEngine(inMemoryCache: {'theme': 'dark'});
        expect(engine.read(['theme']), equals('dark'));
      });

      test('returns value for deeply nested key', () {
        final engine = ConfigEngine(
          inMemoryCache: {
            'app': {
              'ui': {
                'colors': {'primary': '#FF0000'},
              },
            },
          },
        );
        expect(engine.read(['app', 'ui', 'colors', 'primary']), equals('#FF0000'));
      });

      test('returns null if an intermediate segment is not a Map', () {
        final engine = ConfigEngine(inMemoryCache: {'app': 'not_a_map'});
        expect(engine.read(['app', 'ui']), isNull);
      });
    });

    group('write', () {
      test('ignores empty keyPath', () {
        final engine = ConfigEngine(inMemoryCache: {});
        engine.write([], 'value');
        expect(engine.raw, isEmpty);
      });

      test('writes top-level key', () {
        final engine = ConfigEngine(inMemoryCache: {});
        engine.write(['theme'], 'light');
        expect(engine.read(['theme']), equals('light'));
      });

      test('creates intermediate maps for nested keyPath', () {
        final engine = ConfigEngine(inMemoryCache: {});
        engine.write(['ui', 'window', 'width'], 1920);
        expect(engine.read(['ui', 'window', 'width']), equals(1920));
        expect(engine.raw['ui'], isA<Map<String, dynamic>>());
      });

      test('converts non-generic Map to Map<String, dynamic>', () {
        final engine = ConfigEngine(
          inMemoryCache: {
            'group': <dynamic, dynamic>{'existing': 1},
          },
        );
        engine.write(['group', 'newKey'], 2);
        expect(engine.read(['group', 'newKey']), equals(2));
        expect(engine.read(['group', 'existing']), equals(1));
      });

      test('replaces non-map intermediate value with a fresh map', () {
        final engine = ConfigEngine(inMemoryCache: {'ui': 'scalar_value'});
        engine.write(['ui', 'theme'], 'dark');
        expect(engine.read(['ui', 'theme']), equals('dark'));
      });

      test('skips write and notifications if value equals existing (deep equality)', () async {
        final engine = ConfigEngine(
          inMemoryCache: {
            'tags': ['a', 'b'],
            'profile': {'name': 'Alice'},
          },
        );

        final events = <List<String>>[];
        final sub = engine.watchKey(['tags']).listen(events.add);

        // Identical collection written
        engine.write(['tags'], ['a', 'b']);
        await Future<void>.delayed(Duration.zero);

        expect(events, isEmpty);
        await sub.cancel();
      });

      test('notifies watchKey stream when value changes', () async {
        final engine = ConfigEngine(inMemoryCache: {});
        final events = <List<String>>[];
        final sub = engine.watchKey(['ui', 'theme']).listen(events.add);

        engine.write(['ui', 'theme'], 'dark');
        await Future<void>.delayed(Duration.zero);

        expect(events, hasLength(1));
        expect(events.first, equals(['ui', 'theme']));

        await sub.cancel();
      });
    });

    group('writeFirst', () {
      test('prepends key to empty map', () {
        final engine = ConfigEngine(inMemoryCache: {});
        engine.writeFirst('schemaVersion', 1);

        expect(engine.raw.keys.first, equals('schemaVersion'));
        expect(engine.read(['schemaVersion']), equals(1));
      });

      test('prepends key to non-empty map maintaining key order for remaining', () {
        final engine = ConfigEngine(inMemoryCache: {'theme': 'dark', 'volume': 0.8});
        engine.writeFirst('schemaVersion', 2);

        expect(engine.raw.keys.toList(), equals(['schemaVersion', 'theme', 'volume']));
        expect(engine.read(['schemaVersion']), equals(2));
      });

      test('moves existing key to the first position', () {
        final engine = ConfigEngine(inMemoryCache: {'theme': 'dark', 'schemaVersion': 1});
        engine.writeFirst('schemaVersion', 2);

        expect(engine.raw.keys.toList(), equals(['schemaVersion', 'theme']));
        expect(engine.read(['schemaVersion']), equals(2));
      });

      test('does nothing if key is already first with same value', () async {
        final engine = ConfigEngine(inMemoryCache: {'schemaVersion': 1, 'theme': 'dark'});
        final events = <List<String>>[];
        final sub = engine.watchKey(['schemaVersion']).listen(events.add);

        engine.writeFirst('schemaVersion', 1);
        await Future<void>.delayed(Duration.zero);

        expect(events, isEmpty);
        await sub.cancel();
      });
    });

    group('remove', () {
      test('ignores empty keyPath', () {
        final engine = ConfigEngine(inMemoryCache: {'a': 1});
        engine.remove([]);
        expect(engine.raw, equals({'a': 1}));
      });

      test('removes top-level key and notifies listeners', () async {
        final engine = ConfigEngine(inMemoryCache: {'theme': 'dark'});
        final events = <List<String>>[];
        final sub = engine.watchKey(['theme']).listen(events.add);

        engine.remove(['theme']);
        await Future<void>.delayed(Duration.zero);

        expect(engine.read(['theme']), isNull);
        expect(events, hasLength(1));
        expect(events.first, equals(['theme']));

        await sub.cancel();
      });

      test('removes deeply nested key', () {
        final engine = ConfigEngine(
          inMemoryCache: {
            'ui': {'theme': 'dark', 'scale': 1.0},
          },
        );

        engine.remove(['ui', 'theme']);
        expect(engine.read(['ui', 'theme']), isNull);
        expect(engine.read(['ui', 'scale']), equals(1.0));
      });

      test('does not throw or notify if key does not exist', () async {
        final engine = ConfigEngine(inMemoryCache: {'theme': 'dark'});
        final events = <List<String>>[];
        final sub = engine.watchKey(['missing']).listen(events.add);

        engine.remove(['missing']);
        await Future<void>.delayed(Duration.zero);

        expect(events, isEmpty);
        await sub.cancel();
      });
    });

    group('writeDefault and resetAll', () {
      test('writeDefault does nothing when saveDefaultValue is false', () {
        final engine = ConfigEngine(inMemoryCache: {}, saveDefaultValue: false);
        engine.writeDefault(['theme'], 'system');

        expect(engine.read(['theme']), isNull);
      });

      test('writeDefault writes to inMemoryCache if key is missing when saveDefaultValue is true',
          () {
        final engine = ConfigEngine(inMemoryCache: {}, saveDefaultValue: true);
        engine.writeDefault(['theme'], 'system');

        expect(engine.read(['theme']), equals('system'));
      });

      test('writeDefault does not overwrite existing user value in inMemoryCache', () {
        final engine = ConfigEngine(inMemoryCache: {'theme': 'dark'}, saveDefaultValue: true);
        engine.writeDefault(['theme'], 'system');

        expect(engine.read(['theme']), equals('dark'));
      });

      test('resetAll clears entire cache and emits empty path to watchers', () async {
        final engine = ConfigEngine(
          inMemoryCache: {'theme': 'dark', 'scale': 1.0},
          saveDefaultValue: false,
        );

        final events = <List<String>>[];
        final sub = engine.watchKey(['theme']).listen(events.add);

        engine.resetAll();
        await Future<void>.delayed(Duration.zero);

        expect(engine.raw, isEmpty);
        expect(events, hasLength(1));
        expect(events.first, isEmpty); // Empty list matches all watchers

        await sub.cancel();
      });

      test('resetAll restores defaults when saveDefaultValue is true', () {
        final engine = ConfigEngine(inMemoryCache: {}, saveDefaultValue: true);
        engine.writeDefault(['theme'], 'system');

        // User changes value
        engine.write(['theme'], 'dark');
        expect(engine.read(['theme']), equals('dark'));

        // Reset all should revert back to 'system', NOT empty
        engine.resetAll();
        expect(engine.read(['theme']), equals('system'));
      });
    });

    group('containsKey', () {
      test('returns false for empty keyPath', () {
        final engine = ConfigEngine(inMemoryCache: {'a': 1});
        expect(engine.containsKey([]), isFalse);
      });

      test('returns true for existing top-level and nested keys', () {
        final engine = ConfigEngine(
          inMemoryCache: {
            'theme': 'dark',
            'ui': {'scale': 1.0},
          },
        );
        expect(engine.containsKey(['theme']), isTrue);
        expect(engine.containsKey(['ui', 'scale']), isTrue);
      });

      test('returns false for non-existent keys', () {
        final engine = ConfigEngine(
          inMemoryCache: {
            'theme': 'dark',
            'ui': {'scale': 1.0},
          },
        );
        expect(engine.containsKey(['missing']), isFalse);
        expect(engine.containsKey(['ui', 'missing']), isFalse);
        expect(engine.containsKey(['ui', 'scale', 'extra']), isFalse);
      });
    });

    group('watchKey', () {
      test('emits when parent group is overwritten', () async {
        final engine = ConfigEngine(
          inMemoryCache: {
            'ui': {'theme': 'dark'},
          },
        );

        final events = <List<String>>[];
        final sub = engine.watchKey(['ui', 'theme']).listen(events.add);

        // Overwrite parent 'ui'
        engine.write(['ui'], {'theme': 'light'});
        await Future<void>.delayed(Duration.zero);

        expect(events, hasLength(1));
        expect(events.first, equals(['ui']));

        await sub.cancel();
      });

      test('emits when a child key is modified (e.g. map subkey)', () async {
        final engine = ConfigEngine(
          inMemoryCache: {
            'shortcuts': {'save': 'Ctrl+S'},
          },
        );

        final events = <List<String>>[];
        final sub = engine.watchKey(['shortcuts']).listen(events.add);

        engine.write(['shortcuts', 'save'], 'Ctrl+Shift+S');
        await Future<void>.delayed(Duration.zero);

        expect(events, hasLength(1));
        expect(events.first, equals(['shortcuts', 'save']));

        await sub.cancel();
      });

      test('does not emit for sibling keys', () async {
        final engine = ConfigEngine(
          inMemoryCache: {
            'ui': {'theme': 'dark', 'scale': 1.0},
          },
        );

        final events = <List<String>>[];
        final sub = engine.watchKey(['ui', 'theme']).listen(events.add);

        engine.write(['ui', 'scale'], 1.5);
        await Future<void>.delayed(Duration.zero);

        expect(events, isEmpty);
        await sub.cancel();
      });
    });

    group('dispose', () {
      test('closes change controller stream', () async {
        final engine = ConfigEngine(inMemoryCache: {});
        final stream = engine.watchKey(['any']);

        engine.dispose();

        // Stream should complete
        expect(await stream.isEmpty, isTrue);
      });
    });
  });
}
