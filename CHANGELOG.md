## 0.2.0

- **Redesigned API:** Define configs as classes using ConfigBuilder with direct entry handles (`entry.value`, `entry.changes`, `entry.reset()`) replacing legacy `config.get/set/watch` methods.
- **Factory Bootstrapping:** Simplified startup via constructor tear-offs (`Config.initialize(AppConfig.new, file)`) and first-class in-memory testing (`Config.inMemory(AppConfig.new)`).
- **Enums & Lists:** Added `builder.defineEnum(...)` and `builder.defineList(...)` with automatic serialization.
- **Transactional Migrations:** Enhanced schema migrations with step-by-step transactional execution and `ConfigMigrationContext` utilities (`rename`, `transform`, `removePrefix`).
- **Engine & I/O Optimizations:** Enabled synchronous reads during class constructor execution, deep collection equality to prevent redundant disk saves, and hardened atomic file persistence.
- **Zero Dependencies:** Consolidated into a pure Dart package with zero framework coupling (Riverpod integration moved to a README recipe).

## 0.1.0

- Initial release.
- Strongly-typed `ConfigEntry` model with type-safe fallback parsing and serializer support.
- In-memory synchronous frame-0 reads with zero loading latency.
- Debounced atomic file writes (300ms) with auto-creation of missing parent directories.
- Dot-separated key namespacing with automatic nesting into indented JSON on disk.
- Sequential schema migrations with version tracking.
- Automatic quarantine of corrupt JSON files with fallback to clean defaults.
- Desktop file watcher with reload notifications.
- Pure Dart engine with zero framework dependencies.
