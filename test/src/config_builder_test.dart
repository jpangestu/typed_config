import 'package:test/test.dart';
import 'package:typed_config/src/config_builder.dart';
import 'package:typed_config/src/config_engine.dart';
import 'package:typed_config/src/typed_config.dart';

enum TestTheme { system, light, dark }

class Coordinate {
  final int x;
  final int y;

  const Coordinate(this.x, this.y);

  factory Coordinate.fromJson(dynamic json) {
    if (json is Map) {
      return Coordinate((json['x'] as num?)?.toInt() ?? 0, (json['y'] as num?)?.toInt() ?? 0);
    }
    throw const FormatException('Invalid coordinate map');
  }

  Map<String, dynamic> toJson() => {'x': x, 'y': y};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Coordinate && runtimeType == other.runtimeType && x == other.x && y == other.y;

  @override
  int get hashCode => x.hashCode ^ y.hashCode;
}

final class NestedSubConfig extends TypedConfig {
  final ConfigEntry<bool> flag;
  NestedSubConfig(super.builder) : flag = builder.define('flag', true);
}

final class RootTestConfig extends TypedConfig {
  final NestedSubConfig nested;
  RootTestConfig(super.builder) : nested = builder.group('sub', NestedSubConfig.new);
}

void main() {
  group('ConfigBuilder', () {
    late ConfigEngine engine;
    late ConfigBuilder builder;

    setUp(() {
      engine = ConfigEngine(inMemoryCache: {});
      builder = ConfigBuilder(engine: engine, prefixPath: const []);
    });

    group('define', () {
      test('defines entries wired to engine with prefixPath', () {
        final strEntry = builder.define('appName', 'MyApp');
        final intEntry = builder.define('maxCount', 10);
        final boolEntry = builder.define('enabled', false);

        expect(strEntry.value, equals('MyApp'));
        expect(intEntry.value, equals(10));
        expect(boolEntry.value, equals(false));

        strEntry.value = 'NewApp';
        intEntry.value = 42;
        boolEntry.value = true;

        expect(strEntry.value, equals('NewApp'));
        expect(intEntry.value, equals(42));
        expect(boolEntry.value, equals(true));
        expect(engine.read(['appName']), equals('NewApp'));
      });
    });

    group('defineEnum', () {
      test('serializes enum to string name and deserializes correctly', () {
        final themeEntry = builder.defineEnum('theme', TestTheme.system, values: TestTheme.values);

        expect(themeEntry.value, equals(TestTheme.system));

        themeEntry.value = TestTheme.dark;
        expect(engine.read(['theme']), equals('dark'));
        expect(themeEntry.value, equals(TestTheme.dark));
      });

      test('falls back to defaultValue when stored string is unrecognized', () {
        final themeEntry = builder.defineEnum('theme', TestTheme.system, values: TestTheme.values);

        engine.write(['theme'], 'non_existent_mode');
        expect(themeEntry.value, equals(TestTheme.system));
      });

      test('supports nullable enums', () {
        final nullableTheme = builder.defineEnum<TestTheme?>(
          'theme',
          null,
          values: TestTheme.values,
        );

        expect(nullableTheme.value, isNull);

        nullableTheme.value = TestTheme.light;
        expect(nullableTheme.value, equals(TestTheme.light));
        expect(engine.read(['theme']), equals('light'));
      });
    });

    group('defineList', () {
      test('handles lists of String and int', () {
        final tags = builder.defineList<String>('tags', ['initial']);
        expect(tags.value, equals(['initial']));

        tags.value = ['dart', 'flutter'];
        expect(tags.value, equals(['dart', 'flutter']));
        expect(engine.read(['tags']), equals(['dart', 'flutter']));
      });

      test('automatically coerces List<double> elements from int/num', () {
        final listEntry = builder.defineList<double>('numbers', [0.0]);

        // Simulating JSON decode of `[1, 2.5, 3]`
        engine.write(['numbers'], [1, 2.5, 3]);

        expect(listEntry.value, equals([1.0, 2.5, 3.0]));
      });

      test('handles custom object lists with itemFromJson and itemToJson', () {
        final coords = builder.defineList<Coordinate>(
          'points',
          const [],
          itemFromJson: Coordinate.fromJson,
          itemToJson: (c) => c.toJson(),
        );

        coords.value = [const Coordinate(1, 2), const Coordinate(3, 4)];
        expect(
          engine.read(['points']),
          equals([
            {'x': 1, 'y': 2},
            {'x': 3, 'y': 4},
          ]),
        );
        expect(coords.value, equals([const Coordinate(1, 2), const Coordinate(3, 4)]));
      });

      test('falls back to defaultValue when stored value is not a list', () {
        final tags = builder.defineList<String>('tags', ['default']);
        engine.write(['tags'], 'not_a_list');
        expect(tags.value, equals(['default']));
      });
    });

    group('defineMap', () {
      test('handles String keys and values', () {
        final shortcuts = builder.defineMap<String, String>(
          'shortcuts',
          {'save': 'Ctrl+S'},
        );

        expect(shortcuts.value, equals({'save': 'Ctrl+S'}));

        shortcuts.value = {'save': 'Ctrl+Shift+S', 'quit': 'Ctrl+Q'};
        expect(shortcuts.value, equals({'save': 'Ctrl+Shift+S', 'quit': 'Ctrl+Q'}));
        expect(
          engine.read(['shortcuts']),
          equals({'save': 'Ctrl+Shift+S', 'quit': 'Ctrl+Q'}),
        );
      });

      test('handles int keys automatically', () {
        final statusCodes = builder.defineMap<int, String>(
          'status',
          {200: 'OK'},
        );

        expect(statusCodes.value, equals({200: 'OK'}));

        // Simulating JSON where keys on disk are strings
        engine.write(['status'], {'404': 'Not Found', '500': 'Error'});
        expect(statusCodes.value, equals({404: 'Not Found', 500: 'Error'}));

        statusCodes.value = {201: 'Created'};
        expect(engine.read(['status']), equals({'201': 'Created'}));
      });

      test('handles double keys and coerces double values', () {
        final speeds = builder.defineMap<double, double>(
          'speeds',
          {1.0: 1.0},
        );

        // Simulating JSON with numeric strings as keys and int/num as values
        engine.write(['speeds'], {'1.5': 2, '2.0': 2.5});
        expect(speeds.value, equals({1.5: 2.0, 2.0: 2.5}));
      });

      test('handles enum keys with enumValues', () {
        final themeScales = builder.defineMap<TestTheme, double>(
          'themeScales',
          {TestTheme.system: 1.0},
          enumValues: TestTheme.values,
        );

        expect(themeScales.value, equals({TestTheme.system: 1.0}));

        themeScales.value = {TestTheme.light: 1.1, TestTheme.dark: 0.9};
        expect(
          engine.read(['themeScales']),
          equals({'light': 1.1, 'dark': 0.9}),
        );

        // Simulating reading from disk
        engine.write(['themeScales'], {'system': 1.2});
        expect(themeScales.value, equals({TestTheme.system: 1.2}));
      });

      test('handles custom object values with valueFromJson and valueToJson', () {
        final coords = builder.defineMap<String, Coordinate>(
          'positions',
          {'origin': const Coordinate(0, 0)},
          valueFromJson: Coordinate.fromJson,
          valueToJson: (c) => c.toJson(),
        );

        expect(coords.value, equals({'origin': const Coordinate(0, 0)}));

        coords.value = {'target': const Coordinate(10, 20)};
        expect(
          engine.read(['positions']),
          equals({
            'target': {'x': 10, 'y': 20},
          }),
        );
        expect(coords.value, equals({'target': const Coordinate(10, 20)}));
      });

      test('falls back to defaultValue when stored value is not a map', () {
        final shortcuts = builder.defineMap<String, String>(
          'shortcuts',
          {'save': 'Ctrl+S'},
        );

        engine.write(['shortcuts'], 'not_a_map');
        expect(shortcuts.value, equals({'save': 'Ctrl+S'}));
      });

      test('asserts when unsupported key type is used without enumValues', () {
        expect(
          () => builder.defineMap<Coordinate, String>(
            'invalid',
            {},
          ),
          throwsA(isA<AssertionError>()),
        );
      });
    });

    group('group', () {
      test('prepends namespace to child entries', () {
        final rootConfig = RootTestConfig(builder);

        expect(rootConfig.nested.flag.keyPath, equals(['sub', 'flag']));
        expect(rootConfig.nested.flag.value, isTrue);

        rootConfig.nested.flag.value = false;
        expect(engine.read(['sub', 'flag']), equals(false));
      });
    });
  });
}
