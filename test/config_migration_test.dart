import 'package:test/test.dart';
import 'package:typed_config/src/config_migration.dart';

void main() {
  group('parseSchemaVersion', () {
    test('returns exact int when valid', () {
      expect(parseSchemaVersion(1), 1);
      expect(parseSchemaVersion(42), 42);
    });

    test('coerces valid num/double to int', () {
      expect(parseSchemaVersion(3.0), 3);
      expect(parseSchemaVersion(5.9), 5);
    });

    test('parses integer string cleanly', () {
      expect(parseSchemaVersion('2'), 2);
      expect(parseSchemaVersion('10'), 10);
    });

    test('falls back to 1 for invalid, negative, or missing values', () {
      expect(parseSchemaVersion(null), 1);
      expect(parseSchemaVersion(0), 1);
      expect(parseSchemaVersion(-5), 1);
      expect(parseSchemaVersion('invalid'), 1);
      expect(parseSchemaVersion(''), 1);
      expect(parseSchemaVersion('3.14'), 1);
      expect(parseSchemaVersion(true), 1);
    });
  });

  group('migrateConfigData', () {
    test('throws ArgumentError when targetVersion is less than 1', () {
      expect(() => migrateConfigData(data: {}, targetVersion: 0), throwsArgumentError);
      expect(() => migrateConfigData(data: {}, targetVersion: -1), throwsArgumentError);
    });

    test('throws ArgumentError when migration is registered for version 1 or less', () {
      expect(
        () => migrateConfigData(data: {}, targetVersion: 2, migrations: {1: (_) {}}),
        throwsArgumentError,
      );
      expect(
        () => migrateConfigData(data: {}, targetVersion: 2, migrations: {0: (_) {}}),
        throwsArgumentError,
      );
    });

    test('stamps schemaVersion when missing from data', () {
      final input = {'ui.theme': 'dark'};
      final result = migrateConfigData(data: input, targetVersion: 1);

      expect(result.didMigrate, isTrue);
      expect(result.fromVersion, 1);
      expect(result.toVersion, 1);
      expect(result.data['schemaVersion'], 1);
      expect(result.data['ui.theme'], 'dark');
    });

    test('does not run migrations when source is already at target version', () {
      final input = {'schemaVersion': 2, 'ui.theme': 'dark'};
      final result = migrateConfigData(
        data: input,
        targetVersion: 2,
        migrations: {2: (_) => fail('Should not be called')},
      );

      expect(result.didMigrate, isFalse);
      expect(result.fromVersion, 2);
      expect(result.toVersion, 2);
      expect(result.data['ui.theme'], 'dark');
    });

    test('safely handles newer source version than target (future-proof rollback)', () {
      final logs = <String>[];
      final input = {'schemaVersion': 5, 'feature.new': true};
      final result = migrateConfigData(data: input, targetVersion: 3, onLog: logs.add);

      expect(result.didMigrate, isFalse);
      expect(result.fromVersion, 5);
      expect(result.toVersion, 5);
      expect(result.data['feature.new'], true);
      expect(logs.any((l) => l.contains('is newer than current version')), isTrue);
    });

    test('runs multiple sequential migrations in order', () {
      final input = {'schemaVersion': 1, 'count': 10};
      final executionOrder = <int>[];

      final result = migrateConfigData(
        data: input,
        targetVersion: 4,
        migrations: {
          2: (m) {
            executionOrder.add(2);
            m['count'] = (m['count'] as int) + 5;
          },
          3: (m) {
            executionOrder.add(3);
            m['count'] = (m['count'] as int) * 2;
          },
          4: (m) {
            executionOrder.add(4);
            m['count'] = (m['count'] as int) - 1;
          },
        },
      );

      expect(executionOrder, [2, 3, 4]);
      expect(result.didMigrate, isTrue);
      expect(result.fromVersion, 1);
      expect(result.toVersion, 4);
      expect(result.data['count'], 29); // ((10 + 5) * 2) - 1 = 29
      expect(result.data['schemaVersion'], 4);
    });

    test('skips intermediate versions when no migrator is registered', () {
      final input = {'schemaVersion': 1, 'val': 'test'};
      final result = migrateConfigData(
        data: input,
        targetVersion: 3,
        migrations: {
          // v2 omitted intentionally
          3: (m) => m['val'] = 'migrated_to_3',
        },
      );

      expect(result.didMigrate, isTrue);
      expect(result.fromVersion, 1);
      expect(result.toVersion, 3);
      expect(result.data['val'], 'migrated_to_3');
      expect(result.data['schemaVersion'], 3);
    });

    test('automatically re-flattens nested maps introduced during migration', () {
      final input = {'schemaVersion': 1, 'legacy_theme': 'light'};
      final result = migrateConfigData(
        data: input,
        targetVersion: 2,
        migrations: {
          2: (m) {
            final legacy = m.remove('legacy_theme');
            m['ui'] = {'themeMode': legacy, 'fontScale': 1.2};
          },
        },
      );

      expect(result.data['ui.themeMode'], 'light');
      expect(result.data['ui.fontScale'], 1.2);
      expect(result.data.containsKey('ui'), isFalse);
      expect(result.data['schemaVersion'], 2);
    });

    test(
      'transactional rollback: throws ConfigMigrationException and preserves input on error',
      () {
        final input = {'schemaVersion': 1, 'val': 100};
        final logs = <String>[];
        final errors = <Object>[];

        expect(
          () => migrateConfigData(
            data: input,
            targetVersion: 3,
            onLog: logs.add,
            onError: (e, _) => errors.add(e),
            migrations: {
              2: (m) => m['val'] = 200,
              3: (_) => throw const FormatException('Corrupted step 3 migration'),
            },
          ),
          throwsA(
            isA<ConfigMigrationException>()
                .having((e) => e.fromVersion, 'fromVersion', 1)
                .having((e) => e.toVersion, 'toVersion', 3)
                .having((e) => e.failedAtVersion, 'failedAtVersion', 3)
                .having((e) => e.cause, 'cause', isA<FormatException>()),
          ),
        );

        // Caller input remains pristine
        expect(input['val'], 100);
        expect(logs.any((l) => l.contains('Migration to schema version v3 failed')), isTrue);
        expect(errors.isNotEmpty, isTrue);
      },
    );
  });

  group('ConfigMigrationContext', () {
    test('rename moves existing key to new key', () {
      final m = ConfigMigrationContext({'oldKey': 'value123'});
      m.rename('oldKey', 'newKey');

      expect(m.containsKey('oldKey'), isFalse);
      expect(m['newKey'], 'value123');
    });

    test('rename ignores missing oldKey and does nothing', () {
      final m = ConfigMigrationContext(<String, dynamic>{});
      m.rename('oldKey', 'newKey');

      expect(m.containsKey('newKey'), isFalse);
    });

    test('rename preserves existing newKey when oldKey is missing', () {
      final m = ConfigMigrationContext({'newKey': 'existing'});
      m.rename('oldKey', 'newKey');

      expect(m['newKey'], 'existing');
    });

    test('removePrefix deletes all matching keys', () {
      final m = ConfigMigrationContext({
        'analytics.enabled': true,
        'analytics.id': 'abc',
        'ui.theme': 'dark',
      });
      m.removePrefix('analytics.');

      expect(m.containsKey('analytics.enabled'), isFalse);
      expect(m.containsKey('analytics.id'), isFalse);
      expect(m['ui.theme'], 'dark');
    });

    test('transform safely updates matching typed values', () {
      final m = ConfigMigrationContext({'count': 10, 'other': 'hello'});
      m.transform<int>('count', (v) => v * 3);
      m.transform<int>('missing', (v) => v + 1);

      expect(m['count'], 30);
      expect(m.containsKey('missing'), isFalse);
    });

    test('transform allows converting types (e.g. num to double, String to bool)', () {
      final m = ConfigMigrationContext({'volume': 80, 'autoUpdate': 'enabled'});
      m.transform<num>('volume', (v) => (v / 100.0).toDouble());
      m.transform<String>('autoUpdate', (s) => s == 'enabled');

      expect(m['volume'], 0.8);
      expect(m['volume'], isA<double>());
      expect(m['autoUpdate'], isTrue);
      expect(m['autoUpdate'], isA<bool>());
    });

    test('index operators and map access work correctly', () {
      final m = ConfigMigrationContext({'a': 1});
      expect(m['a'], 1);
      m['b'] = 2;
      expect(m['b'], 2);
      expect(m.containsKey('b'), isTrue);
      expect(m.remove('a'), 1);
      expect(m.containsKey('a'), isFalse);
      expect(m.keys, ['b']);
      expect(m.data, {'b': 2});
    });

    test('operator []= automatically flattens nested maps inline', () {
      final m = ConfigMigrationContext(<String, dynamic>{});
      m['ui'] = {
        'theme': 'dark',
        'font': {'size': 14},
      };

      expect(m['ui.theme'], 'dark');
      expect(m['ui.font.size'], 14);
      expect(m.containsKey('ui'), isFalse);
      expect(m.containsKey('ui.font'), isFalse);
    });
  });
}
