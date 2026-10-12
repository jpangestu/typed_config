## 0.2.0

- **Consumer-First API:** Adopted Dart Primary Constructors and `ConfigBuilder` for domain-driven organization (`config.audio.volume.value`) and nested domain grouping (`builder.withPrefix('audio')`).
- **Direct Entry Handles:** Direct synchronous `.value` access, `.value =` assignment, `.reset()`, and `.changes` stream on entries.
- **Factory Bootstrapping:** Replaced static descriptor registry with constructor tear-off initialization (`Config.initialize(AppConfig.new, file)`).
- **In-Memory Testing:** First-class support for in-memory testing without file I/O via `Config.inMemory(AppConfig.new)`.
- **Zero-Boilerplate Enums & Lists:** Added `builder.define(...)`, `builder.defineEnum(...)`, and `builder.defineList(...)`.
- **API Simplification:** Removed legacy `config.get()`, `config.set()`, `config.reset()`, and `config.watch()` methods in favor of direct handle operations.
- **Clean Public Surface & Aliases:** Streamlined exports to `Config`, `ConfigBuilder`, `ConfigEntry`, and `ConfigMigrator`, with symmetrical `Typed*` aliases (`TypedConfig`, `TypedConfigBuilder`, `TypedConfigEntry`) to prevent naming collisions.
- **Package Consolidation:** Restructured monorepo into a single, zero-dependency Dart package (Riverpod integration moved to a lightweight recipe in the README).


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
