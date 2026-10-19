# Contributing to Swivel

Thanks for helping. Bug reports, format requests and pull requests are all welcome.

## Reporting a bug or asking for a format

Use the [issue forms](https://github.com/jonathanlotan/Swivel/issues/new/choose). For a bug,
the macOS version, the kind of file (a sample helps, if it isn't private) and what happened
are usually enough. Questions and ideas fit better in
[Discussions](https://github.com/jonathanlotan/Swivel/discussions).

## Building and testing

You need Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
make run          # build and open the app
make test         # all tests: the conversion engine and the app
make core-test    # only the engine (fast, no Xcode project needed)
```

`make readme-images` re-renders the pictures in the README from the app's views. Run it when
a change alters how the wheel or a window looks, and commit the new images.

## Ground rules for changes

- **No network code.** Swivel never touches the network, and `OfflineTests` and
  `OfflineAppTests` fail the build if networking APIs are linked. This includes update
  checks, analytics and crash reporting.
- **Apple frameworks and tools that ship with macOS only.** A third-party encoder
  (libwebp, LAME, ffmpeg…) needs an issue first, to talk through licensing and size.
- **`ConverterCore` stays free of UI.** It doesn't import AppKit or SwiftUI; app-only
  converters live in `Converter/App` and are registered by the app.
- **Every conversion is tested.** The matrix tests convert every pair a converter
  accepts and check the result opens with the right type, size, duration or page count.
  A new converter gets picked up by them; give it samples if it needs new ones.
- **Originals are never changed and results never overwrite anything.** Run jobs through
  `JobRunner`, which writes to a temporary folder and moves the result into place.
- Keep pull requests small and focused, and describe how you tested them.

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
