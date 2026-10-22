import 'package:test/test.dart';
import 'package:typed_config/src/config_engine.dart';
import 'package:typed_config/src/config_migrator.dart';
import 'package:typed_config/src/typed_config.dart';

class SampleConfig extends TypedConfig {
  SampleConfig(super.builder);
  late final theme = builder.define('theme', 'light');
  late final user = builder.define<Map<String, dynamic>>('user', const {});
}

void main() {
  group('ConfigMigrator', () {
    late ConfigEngine engine;
    late ConfigMigrator migrator;

    setUp(() {
      engine = ConfigEngine(
        inMemoryCache: {
          'oldTheme': 'dark',
          'profile': {'firstName': 'John'},
        },
      );
      migrator = ConfigMigrator(configEngine: engine, fromVersion: 1, toVersion: 2);
    });

    group('rename', () {
      test('moves value from oldKeyPath to newKeyPath and deletes old key', () {
        migrator.rename(['oldTheme'], ['ui', 'theme']);

        expect(migrator.containsKey(['oldTheme']), isFalse);
        expect(migrator.read(['ui', 'theme']), equals('dark'));
      });

      test('does nothing if oldKeyPath does not exist', () {
        migrator.rename(['nonExistent'], ['target']);
        expect(migrator.containsKey(['target']), isFalse);
      });

      test('does nothing if oldKeyPath and newKeyPath are identical or empty', () {
        migrator.rename([], ['ui', 'theme']);
        migrator.rename(['oldTheme'], []);
        migrator.rename(['oldTheme'], ['oldTheme']);

        expect(migrator.read(['oldTheme']), equals('dark'));
      });
    });

    group('transform', () {
      test('updates value using transformation callback', () {
        migrator.transform(['oldTheme'], (oldVal) => (oldVal as String).toUpperCase());
        expect(migrator.read(['oldTheme']), equals('DARK'));
      });

      test('does nothing if keyPath does not exist or is empty', () {
        var called = false;
        migrator.transform(['missing'], (val) {
          called = true;
          return val;
        });
        migrator.transform([], (val) {
          called = true;
          return val;
        });

        expect(called, isFalse);
      });
    });

    group('Config migration pipeline', () {
      test('stamps schemaVersion without running migrations on first setup', () {
        var migrationRan = false;
        final config = TypedConfig.inMemory(
          create: SampleConfig.new,
          schemaVersion: 2,
          migrations: {2: (m) => migrationRan = true},
        );

        expect(migrationRan, isFalse);
        expect(config.builder.engine.read([TypedConfig.schemaVersionKey]), equals(2));
      });

      test('runs sequential migrations (v1 -> v2 -> v3) on existing data', () {
        final order = <int>[];

        final config = TypedConfig.inMemory(
          create: SampleConfig.new,
          initialData: {'schemaVersion': 1, 'legacyName': 'hello'},
          schemaVersion: 3,
          migrations: {
            2: (m) {
              order.add(2);
              m.rename(['legacyName'], ['renamedName']);
            },
            3: (m) {
              order.add(3);
              m.transform(['renamedName'], (val) => '$val world');
            },
          },
        );

        expect(order, equals([2, 3]));
        expect(config.builder.engine.read(['renamedName']), equals('hello world'));
        expect(config.builder.engine.read([TypedConfig.schemaVersionKey]), equals(3));
      });

      test('defaults unversioned initial data to v1 and runs migrations to target', () {
        final config = TypedConfig.inMemory(
          create: SampleConfig.new,
          initialData: {'legacy': 'val'},
          schemaVersion: 2,
          migrations: {
            2: (m) => m.rename(['legacy'], ['migrated']),
          },
        );

        expect(config.builder.engine.read(['migrated']), equals('val'));
        expect(config.builder.engine.read([TypedConfig.schemaVersionKey]), equals(2));
      });

      test('rethrows error and invokes onError if a migration fails', () {
        Object? capturedError;
        final logs = <String>[];

        expect(
          () => TypedConfig.inMemory(
            create: SampleConfig.new,
            initialData: {'schemaVersion': 1},
            schemaVersion: 2,
            migrations: {2: (m) => throw Exception('Migration error!')},
            onLog: logs.add,
            onError: (err, stack) => capturedError = err,
          ),
          throwsException,
        );

        expect(capturedError, isNotNull);
        expect(logs.any((l) => l.contains('failed')), isTrue);
      });

      test('logs warning when schemaVersion in data is newer than current schema', () {
        final logs = <String>[];

        final config = TypedConfig.inMemory(
          create: SampleConfig.new,
          initialData: {'schemaVersion': 5},
          schemaVersion: 2,
          onLog: logs.add,
        );

        expect(config.builder.engine.read([TypedConfig.schemaVersionKey]), equals(5));
        expect(logs.any((l) => l.contains('newer than current version')), isTrue);
      });
    });
  });
}
