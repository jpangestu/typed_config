import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:typed_config/src/typed_config.dart';

final class TestConfig extends TypedConfig {
  TestConfig(super.builder);
  late final appName = builder.define('appName', 'DefaultApp');
  late final theme = builder.define('theme', 'system');
  late final port = builder.define('port', 8080);
}

void main() {
  group('Config Persistence & Lifecycle', () {
    late Directory tempDir;
    late File configFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('typed_config_test_');
      configFile = File('${tempDir.path}/app_config.json');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    group('TypedConfig.inMemory', () {
      test('operates without touching disk', () async {
        final config = TypedConfig.inMemory(create: TestConfig.new);

        config.appName.value = 'InMemoryApp';
        await config.flush();

        expect(await configFile.exists(), isFalse);
        config.dispose();
      });

      test('deep copies initialData to prevent external map mutation leaks', () {
        final mutableMap = <String, dynamic>{'appName': 'Initial'};
        final config = TypedConfig.inMemory(create: TestConfig.new, initialData: mutableMap);

        // Mutate the original map externally
        mutableMap['appName'] = 'MutatedOutside';

        // Config should maintain its isolated state
        expect(config.appName.value, equals('Initial'));
        config.dispose();
      });

      test('resetAll clears entries and preserves schemaVersion in memory', () async {
        final config = TypedConfig.inMemory(
          create: TestConfig.new,
          initialData: {'schemaVersion': 2, 'appName': 'CustomApp'},
          schemaVersion: 2,
        );

        expect(config.appName.value, equals('CustomApp'));

        await config.resetAll();

        expect(config.appName.value, equals('DefaultApp'));
        expect(config.builder.engine.read([TypedConfig.schemaVersionKey]), equals(2));
        config.dispose();
      });
    });

    group('TypedConfig.initialize', () {
      test('initializes with defaults when file does not exist', () async {
        final config = await TypedConfig.initialize(configFile: configFile, create: TestConfig.new);

        expect(config.appName.value, equals('DefaultApp'));
        expect(config.port.value, equals(8080));

        // File should exist because initialize flushes schema version
        expect(await configFile.exists(), isTrue);
        final diskData = jsonDecode(await configFile.readAsString());
        expect(diskData[TypedConfig.schemaVersionKey], equals(1));

        config.dispose();
      });

      test('loads existing valid configuration from disk', () async {
        await configFile.writeAsString(
          jsonEncode({'appName': 'DiskApp', 'port': 9090, 'schemaVersion': 1}),
        );

        final config = await TypedConfig.initialize(configFile: configFile, create: TestConfig.new);

        expect(config.appName.value, equals('DiskApp'));
        expect(config.port.value, equals(9090));
        expect(config.theme.value, equals('system')); // default

        config.dispose();
      });

      test('debounces saves to disk', () async {
        final config = await TypedConfig.initialize(
          configFile: configFile,
          create: TestConfig.new,
          debounceDuration: const Duration(milliseconds: 100),
        );

        config.appName.value = 'DebouncedApp';

        // Immediately after writing, disk content should not yet reflect the change
        var diskData = jsonDecode(await configFile.readAsString());
        expect(diskData['appName'], isNull);

        // Wait for debounce timer
        await Future<void>.delayed(const Duration(milliseconds: 150));

        diskData = jsonDecode(await configFile.readAsString());
        expect(diskData['appName'], equals('DebouncedApp'));

        config.dispose();
      });

      test('flush persists changes immediately', () async {
        final config = await TypedConfig.initialize(
          configFile: configFile,
          create: TestConfig.new,
          debounceDuration: const Duration(seconds: 10),
        );

        config.appName.value = 'FlushedApp';
        await config.flush();

        final diskData = jsonDecode(await configFile.readAsString());
        expect(diskData['appName'], equals('FlushedApp'));

        config.dispose();
      });

      test('dispose synchronously persists pending changes', () async {
        final config = await TypedConfig.initialize(
          configFile: configFile,
          create: TestConfig.new,
          debounceDuration: const Duration(seconds: 10),
        );

        config.appName.value = 'DisposedApp';

        // Synchronously dispose without awaiting a flush
        config.dispose();

        final diskData = jsonDecode(await configFile.readAsString());
        expect(diskData['appName'], equals('DisposedApp'));
      });

      test('resetAll clears entries and preserves schemaVersion on disk', () async {
        final config = await TypedConfig.initialize(
          configFile: configFile,
          create: TestConfig.new,
          schemaVersion: 3,
        );

        config.appName.value = 'ChangedApp';
        await config.flush();

        await config.resetAll();

        final diskData = jsonDecode(await configFile.readAsString());
        expect(diskData['appName'], isNull);
        expect(diskData[TypedConfig.schemaVersionKey], equals(3));

        config.dispose();
      });
    });

    group('Concurrency & Race Condition Handling', () {
      test('handles concurrent flush calls safely via _isFlushing guard', () async {
        final config = await TypedConfig.initialize(configFile: configFile, create: TestConfig.new);

        config.appName.value = 'ConcurrentApp';

        // Fire multiple simultaneous flushes
        await Future.wait([config.flush(), config.flush(), config.flush()]);

        final diskData = jsonDecode(await configFile.readAsString());
        expect(diskData['appName'], equals('ConcurrentApp'));

        // Verify no leftover .tmp file
        final tmpFile = File('${configFile.path}.tmp');
        expect(await tmpFile.exists(), isFalse);

        config.dispose();
      });

      test('dirty writes during in-flight flush are preserved', () async {
        final config = await TypedConfig.initialize(
          configFile: configFile,
          create: TestConfig.new,
          debounceDuration: const Duration(milliseconds: 50),
        );

        config.appName.value = 'FirstUpdate';
        final flushFuture = config.flush();

        // Mutate immediately during the async flush
        config.theme.value = 'dark';
        await flushFuture;

        // Give the debounced save for 'theme' a moment to fire
        await Future<void>.delayed(const Duration(milliseconds: 100));

        final diskData = jsonDecode(await configFile.readAsString());
        expect(diskData['appName'], equals('FirstUpdate'));
        expect(diskData['theme'], equals('dark'));

        config.dispose();
      });
    });

    group('Corrupt File Quarantine', () {
      test('quarantines malformed JSON, notifies error, and starts with defaults', () async {
        await configFile.writeAsString('{ invalid_json: ');

        Object? capturedError;
        final logs = <String>[];

        final config = await TypedConfig.initialize(
          configFile: configFile,
          create: TestConfig.new,
          onLog: logs.add,
          onError: (err, stack) => capturedError = err,
        );

        expect(config.appName.value, equals('DefaultApp'));
        expect(capturedError, isNotNull);

        // Verify corrupt file was created
        final corruptFiles =
            tempDir.listSync().whereType<File>().where((f) => f.path.contains('.corrupt')).toList();

        expect(corruptFiles, hasLength(1));
        expect(await corruptFiles.first.readAsString(), equals('{ invalid_json: '));

        config.dispose();
      });

      test('quarantines non-map JSON object (e.g. array)', () async {
        await configFile.writeAsString('[1, 2, 3]');

        Object? capturedError;
        final config = await TypedConfig.initialize(
          configFile: configFile,
          create: TestConfig.new,
          onError: (err, stack) => capturedError = err,
        );

        expect(config.appName.value, equals('DefaultApp'));
        expect(capturedError, isA<FormatException>());

        final corruptFiles =
            tempDir.listSync().whereType<File>().where((f) => f.path.contains('.corrupt')).toList();

        expect(corruptFiles, hasLength(1));
        expect(await corruptFiles.first.readAsString(), equals('[1, 2, 3]'));

        config.dispose();
      });

      test('prunes older corrupt files keeping at most 1 corrupt file', () async {
        // Create an existing older .corrupt file
        final oldCorrupt = File('${configFile.path}.20200101_000000.corrupt');
        await oldCorrupt.writeAsString('old corrupted data');

        // New corrupt main file
        await configFile.writeAsString('new broken json');

        final config = await TypedConfig.initialize(configFile: configFile, create: TestConfig.new);

        final corruptFiles =
            tempDir.listSync().whereType<File>().where((f) => f.path.contains('.corrupt')).toList();

        expect(corruptFiles, hasLength(1));
        expect(await corruptFiles.first.readAsString(), equals('new broken json'));
        expect(await oldCorrupt.exists(), isFalse);

        config.dispose();
      });
    });

    group('Windows file locking & atomic rename fallback', () {
      test('recovers and persists successfully once file lock contention is released', () async {
        Object? capturedError;
        final config = await TypedConfig.initialize(
          configFile: configFile,
          create: TestConfig.new,
          onError: (err, stack) => capturedError = err,
        );

        config.appName.value = 'LockTestApp';

        RandomAccessFile? lockedRaf;
        if (Platform.isWindows) {
          try {
            // Holding exclusive lock on Windows triggers FileSystemException on write
            lockedRaf = await configFile.open(mode: FileMode.read);
          } catch (_) {}
        }

        try {
          await config.flush();
        } finally {
          await lockedRaf?.close();
        }

        if (Platform.isWindows) {
          expect(capturedError, isA<FileSystemException>());
        }

        // Retry flush after lock is released
        await config.flush();

        final diskData = jsonDecode(await configFile.readAsString());
        expect(diskData['appName'], equals('LockTestApp'));

        config.dispose();
      });
    });
  });
}
