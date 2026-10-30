import 'dart:async';

import 'package:test/test.dart';
import 'package:typed_config/src/config_builder.dart';
import 'package:typed_config/src/config_engine.dart';

void main() {
  group('ConfigEntry', () {
    late ConfigEngine engine;

    setUp(() {
      engine = ConfigEngine(inMemoryCache: {});
    });

    group('value getter and setter', () {
      test('returns defaultValue when key is absent', () {
        final entry = ConfigEntry<String>(
          keyPath: ['theme'],
          defaultValue: 'system',
          engine: engine,
        );

        expect(entry.value, equals('system'));
      });

      test('returns stored value when key is present', () {
        engine.write(['theme'], 'dark');

        final entry = ConfigEntry<String>(
          keyPath: ['theme'],
          defaultValue: 'system',
          engine: engine,
        );

        expect(entry.value, equals('dark'));
      });

      test('handles nullable types with explicit null stored', () {
        engine.write(['avatar'], null);

        final entry = ConfigEntry<String?>(
          keyPath: ['avatar'],
          defaultValue: 'default_avatar.png',
          engine: engine,
        );

        expect(entry.value, isNull);
      });

      test('falls back to defaultValue if stored value is null for non-nullable type', () {
        engine.write(['count'], null);

        final entry = ConfigEntry<int>(keyPath: ['count'], defaultValue: 42, engine: engine);

        expect(entry.value, equals(42));
      });

      test('coerces num to double when T is double', () {
        engine.write(['scale'], 2); // int 2

        final entry = ConfigEntry<double>(keyPath: ['scale'], defaultValue: 1.0, engine: engine);

        expect(entry.value, equals(2.0));
      });

      test('uses toJson on write and fromJson on read', () {
        final entry = ConfigEntry<DateTime>(
          keyPath: ['lastLogin'],
          defaultValue: DateTime.fromMillisecondsSinceEpoch(0),
          fromJson: (json) => DateTime.parse(json as String),
          toJson: (dt) => dt.toIso8601String(),
          engine: engine,
        );

        final now = DateTime.utc(2026, 10, 18, 12, 0, 0);
        entry.value = now;

        expect(engine.read(['lastLogin']), equals('2026-10-18T12:00:00.000Z'));
        expect(entry.value, equals(now));
      });

      test('falls back to defaultValue when fromJson throws', () {
        final entry = ConfigEntry<DateTime>(
          keyPath: ['lastLogin'],
          defaultValue: DateTime.fromMillisecondsSinceEpoch(0),
          fromJson: (json) => DateTime.parse(json as String),
          engine: engine,
        );

        engine.write(['lastLogin'], 'invalid_date_format');
        expect(entry.value, equals(DateTime.fromMillisecondsSinceEpoch(0)));
      });
    });

    group('isDefault and reset', () {
      test('isDefault is true initially and false after update', () {
        final entry = ConfigEntry<String>(
          keyPath: ['title'],
          defaultValue: 'Untitled',
          engine: engine,
        );

        expect(entry.isDefault, isTrue);

        entry.value = 'My Note';
        expect(entry.isDefault, isFalse);

        entry.reset();
        expect(entry.isDefault, isTrue);
        expect(entry.value, equals('Untitled'));
      });
    });

    test('reset sets value to defaultValue in storage when saveDefaultValue is true', () {
      final denseEngine = ConfigEngine(inMemoryCache: {}, saveDefaultValue: true);
      final entry = ConfigEntry<String>(
        keyPath: ['theme'],
        defaultValue: 'system',
        engine: denseEngine,
      );

      entry.value = 'dark';
      expect(denseEngine.read(['theme']), equals('dark'));

      entry.reset();
      expect(entry.value, equals('system'));
      expect(denseEngine.containsKey(['theme']), isTrue); // Key is retained!
      expect(entry.isDefault, isTrue);
    });

    group('changes stream', () {
      test('emits value updates and ignores consecutive duplicates', () async {
        final entry = ConfigEntry<List<String>>(
          keyPath: ['tags'],
          defaultValue: const [],
          engine: engine,
        );

        final events = <List<String>>[];
        final sub = entry.changes.listen(events.add);

        entry.value = ['dart'];
        await Future<void>.delayed(Duration.zero);

        // Setting a distinct new list with same items should be ignored by distinct()
        entry.value = ['dart'];
        await Future<void>.delayed(Duration.zero);

        entry.value = ['dart', 'flutter'];
        await Future<void>.delayed(Duration.zero);

        expect(events, hasLength(2));
        expect(events[0], equals(['dart']));
        expect(events[1], equals(['dart', 'flutter']));

        await sub.cancel();
      });

      test('emits defaultValue when entry is reset', () async {
        final entry = ConfigEntry<String>(
          keyPath: ['font'],
          defaultValue: 'Roboto',
          engine: engine,
        );

        entry.value = 'Fira Code';

        final events = <String>[];
        final sub = entry.changes.listen(events.add);

        entry.reset();
        await Future<void>.delayed(Duration.zero);

        expect(events, equals(['Roboto']));
        await sub.cancel();
      });
    });

    test('toString returns formatted string', () {
      final entry = ConfigEntry<int>(keyPath: ['count'], defaultValue: 10, engine: engine);

      expect(entry.toString(), equals('ConfigEntry<int>([count]: 10)'));
    });
  });
}
