# typed_config Monorepo

A type-safe key-value store for application configurations with synchronous in-memory reads, disk persistence, and reactive state management.

## Packages

| Package | pub.dev | Description |
| :--- | :--- | :--- |
| [**`typed_config`**](packages/typed_config) | [![pub package](https://img.shields.io/pub/v/typed_config.svg)](https://pub.dev/packages/typed_config) | Core pure Dart engine with debounced disk persistence, schema migrations, and crash recovery. Zero framework dependencies. |
| [**`typed_config_riverpod`**](packages/typed_config_riverpod) | [![pub package](https://img.shields.io/pub/v/typed_config_riverpod.svg)](https://pub.dev/packages/typed_config_riverpod) | Riverpod state management bindings, `ConfigNotifier`, and fine-grained `configEntryProvider` utilities. |

---

## Architecture

This repository is maintained as a modular monorepo:

- **`packages/typed_config`** has **zero framework dependencies** (only `collection`, `path`, and `meta`). It is 100% pure Dart and can run in any Dart environment (Flutter, CLI tools, server apps, backend scripts).
- **`packages/typed_config_riverpod`** brings fine-grained reactive state management to Flutter & Dart apps using Riverpod without polluting the core engine with external framework coupling.

---

## Contributing

```bash
# Clone repository
git clone https://github.com/my_org/typed_config.git
cd typed_config

# Run tests in core package
cd packages/typed_config
dart pub get
dart test

# Run tests in riverpod package
cd ../typed_config_riverpod
dart pub get
dart test
```
