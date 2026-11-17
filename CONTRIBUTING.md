# Contributing

Bug reports, fixes and translations are welcome. For a new feature, open an issue first so we can agree on it before you write the code.

## Build and test

Needs full Xcode 26 or later, selected as the active developer directory. Packaging uses `actool` for the icon assets, and tests require XCTest; Command Line Tools alone are not enough.

```sh
./scripts/make-cert.sh          # once: local certificate, so the Accessibility grant survives rebuilds
./scripts/build-app.sh          # → build/Bowerbird.app
swift test
```

## App icon

`Support/Bowerbird.png` is the approved source artwork. After changing it, regenerate the macOS icon:

```sh
swift scripts/make-icon.swift
```

This adds transparent macOS margins and exports standard and Retina sizes to
`Support/Bowerbird.icns` for the disk image, plus a matching compiled ICNS and asset catalog
in `build/icon-resources/` for the app bundle. Keep those compiled files together.
The named catalog prevents modern macOS from adding a second background around the icon.
Both app and DMG builds regenerate and include these resources automatically.
The menu bar uses separate system symbols.

## Release checks

`scripts/make-dmg.sh` builds a universal app, removes debug symbols before signing,
and checks the mounted disk image. Release builds also scan every byte of the app
for personal build paths, including both architecture slices and their symbol tables.
The check fails if the version or bundled licenses differ from the source files.

`LICENSE` and `THIRD_PARTY_NOTICES.md` are included in the app's Resources folder.
When updating dependencies, update the versions and license texts in
`THIRD_PARTY_NOTICES.md` as well.

## Test with a separate data folder

The app stores real clipboard history. To try a change without touching yours, quit the installed app and start the build with its own folder:

```sh
BOWERBIRD_DATA_DIR=/tmp/bowerbird-dev build/Bowerbird.app/Contents/MacOS/Bowerbird
```

Settings are still shared with the installed app, so a retention period you change here applies to your real history the next time that app starts.

## What a pull request needs

- `swift test` passes.
- A test for the behaviour you changed, where one can be written.
- Every new interface string added to all seven `Support/*.lproj/Localizable.strings` files. `LocalizationTests` fails if one is missing.
- No network access and no new permissions. These are the app's promises to its users.

## Reporting a security problem

See [SECURITY.md](SECURITY.md). Please don't open a public issue for it.
