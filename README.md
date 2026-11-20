# Venera Edge
[![flutter](https://img.shields.io/badge/flutter-3.50.0-blue)](https://flutter.dev/)
[![License](https://img.shields.io/github/license/Yo1sing/Venera-Edge)](https://github.com/Yo1sing/Venera-Edge/blob/master/LICENSE)
[![stars](https://img.shields.io/github/stars/Yo1sing/Venera-Edge?style=flat)](https://github.com/Yo1sing/Venera-Edge/stargazers)

[![Download](https://img.shields.io/github/v/release/Yo1sing/Venera-Edge)](https://github.com/Yo1sing/Venera-Edge/releases)

A comic reader that supports reading local and network comics, forked from [Venera](https://github.com/venera-app/venera).

Application ID: `io.github.yo1sing.venera.edge`.

The AltStore source is initialized without upstream releases. After publishing the first Venera Edge IPA, run `update_alt_store.py` to populate it with this fork's release information.

## Features
- Read local comics
- Use javascript to create comic sources
- Read comics from network sources
- Manage favorite comics
- Download comics
- View comments, tags, and other information of comics if the source supports
- Login to comment, rate, and other operations if the source supports

## Build from source

On Windows, run this once after installing Git for Windows and before cloning the repository:

```sh
git config --global core.longpaths true
```

Flutter uses Git to check out `flutter_inappwebview` into the Pub cache, where
some Android Java source paths reach the default Windows path limit. If you
already cloned Venera Edge, enable this setting before Flutter first fetches
its dependencies. You can keep your existing clone.

1. Clone the repository
2. Install flutter, see [flutter.dev](https://flutter.dev/docs/get-started/install)
3. Install rust, see [rustup.rs](https://rustup.rs/)
4. On Windows, install LLVM with `winget install --id LLVM.LLVM --exact`.
   The Rust backend uses `bindgen` to load `libclang.dll` during the build.
   Set `LIBCLANG_PATH` to the LLVM `bin` directory in the terminal where you
   will run Flutter. For the default install location, use one of these commands:

   ```powershell
   $env:LIBCLANG_PATH = 'C:\Program Files\LLVM\bin'
   ```

   ```bash
   # Git Bash or MSYS2
   export LIBCLANG_PATH='C:/Program Files/LLVM/bin'
   ```

5. Build for your platform: e.g. `flutter build apk`

See the [backend architecture and build guide](doc/backend_architecture.md)
for the Rust toolchain, FRB generation, native tests, and platform verification.

## Create a new comic source
See [Comic Source](doc/comic_source.md)

## Thanks

### Tags Translation
[EhTagTranslation](https://github.com/EhTagTranslation/Database)

The Chinese translation of the manga tags is from this project.

## Headless Mode
See [Headless Doc](doc/headless_doc.md)

