import 'src/config.dart';
import 'src/config_builder.dart';
import 'src/config_entry.dart';

export 'src/config.dart' show Config, ConfigMigrator;
export 'src/config_builder.dart' show ConfigBuilder;
export 'src/config_entry.dart' show ConfigEntry;

/// Convenient alias for [Config] to avoid name collisions in projects with an existing `Config` class.
typedef TypedConfig = Config;

/// Convenient alias for [ConfigBuilder] to pair symmetrically with [TypedConfig].
typedef TypedConfigBuilder = ConfigBuilder;

/// Convenient alias for [ConfigEntry] to pair symmetrically with [TypedConfig].
typedef TypedConfigEntry<T> = ConfigEntry<T>;
