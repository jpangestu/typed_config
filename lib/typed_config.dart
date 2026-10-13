import 'src/config.dart';
import 'src/config_builder.dart';
import 'src/config_entry.dart';
import 'src/config_migration.dart';

export 'src/config.dart' show Config;
export 'src/config_builder.dart' show ConfigBuilder;
export 'src/config_entry.dart' show ConfigEntry;
export 'src/config_migration.dart'
    show ConfigMigrator, ConfigMigrationException, ConfigMigrationResult, ConfigMigrationContext;

/// Convenient alias for [Config] to avoid name collisions in projects with an existing `Config` class.
typedef TypedConfig = Config;

/// Convenient alias for [ConfigBuilder] to pair symmetrically with [TypedConfig].
typedef TypedConfigBuilder = ConfigBuilder;

/// Convenient alias for [ConfigEntry] to pair symmetrically with [TypedConfig].
typedef TypedConfigEntry<T> = ConfigEntry<T>;

/// Convenient alias for [ConfigMigrator] to pair symmetrically with [TypedConfig].
typedef TypedConfigMigrator = ConfigMigrator;

/// Convenient alias for [ConfigMigrationException] to pair symmetrically with [TypedConfig].
typedef TypedConfigMigrationException = ConfigMigrationException;

/// Convenient alias for [ConfigMigrationContext] to pair symmetrically with [TypedConfig].
typedef TypedConfigMigrationContext = ConfigMigrationContext;

/// Convenient alias for [ConfigMigrationContext] to pair symmetrically with [TypedConfig].
typedef TypedMigrationContext = ConfigMigrationContext;
