# File converter for Mac

A native macOS menu bar app that converts, edits and shares files without
uploading them anywhere. Start dragging files in Finder, tap a key, and drop
them on a wheel of choices that appears at the pointer. The result is saved
next to the original, which is never changed. Working name: **Converter**.

- Fully offline: no network access, accounts or telemetry.
- Apple silicon, macOS 13 or later. Liquid Glass on macOS 26 and later.
- Uses only Apple's frameworks (ImageIO, AVFoundation, AudioToolbox, PDFKit,
  Vision) and tools that ship with macOS (`textutil`, `ditto`, `tar`, `aa`).

## Using it

While dragging files, **tap** a key to open the wheel:

| Key | Ring | What's in it |
|---|---|---|
| ⇧ Shift | Convert | Formats the files can become: images, video, audio, documents, PDFs |
| ⌘ Command | Tools | Resize, crop, compress, remove metadata, recognize text, merge or split PDFs, archive |
| ⌃ Control | Actions | Share (AirDrop, Mail, Messages, Notes, Photos, or the system share sheet), metadata, float on a shelf, copy, move, copy path, open in Terminal |

- Scroll to switch rings: up for the next one, in the order Actions, Tools,
  Convert. You can also tap another key.
- Drop on a slice to run it, or in the centre to cancel. Slices with a ›
  open a second ring when you hover over them.
- The keys can be changed in Settings.

Other ways in: drop files on the menu bar icon, choose **Convert Files…**
from its menu, use **Services › Convert with Converter…** or the Quick
Action in Finder, or use **Open With**.

Results get Finder-style names: `photo.jpg` becomes `photo 2.jpg`,
`photo (square).jpg` or `photo (1920px).jpg`, and nothing is ever overwritten.

## What it handles

- **Images:** JPEG, PNG, HEIC, AVIF, TIFF, GIF, BMP, WebP (read), JPEG 2000,
  PSD, ICO, ICNS, TGA, EXR (read), SVG (read), PDF. Animated GIFs can become
  MP4 or MOV.
- **Video:** MP4 (H.264 or HEVC), MOV (including ProRes), M4V, GIF, a still
  frame, or the sound as M4A, WAV, AIFF or FLAC. Compress, resize, remove
  audio.
- **Audio:** M4A (AAC or lossless), WAV, AIFF, FLAC, AAC, CAF.
- **Documents:** TXT, RTF, HTML, Word, OpenDocument, and text to PDF. PDF to
  text or images. Merge, split and compress PDFs, and combine images into a
  PDF. Recognize text in images.
- **Archives:** extract or create ZIP, TAR.GZ, TAR.XZ, 7Z and Apple Archive,
  and convert between them.
- **Crop:** square and common aspect ratios from the centre, or a crop editor
  with handles, a choice of shape, and an exact output size.
- **Metadata:** a window with file details, camera and exposure, location,
  captions, audio and video tracks, and PDF info, with Copy All.

Formats that would need third-party encoders (WebP and JPEG XL writing, MP3,
Ogg, WebM, MKV) aren't included.

## Building

You need Xcode 26 or later (for the Icon Composer app icon; built and tested
with Xcode 27.1) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
make test
```

| Command | What it does |
|---|---|
| `make app` | Generates the Xcode project and builds the app |
| `make run` | Builds and opens the app |
| `make test` | Runs the core and app tests |
| `make core-test` | Runs only the `ConverterCore` tests |
| `make cli` | Builds `converter-cli` and prints its path |
| `make clean` | Removes the build output |

Builds go to `~/Library/Caches/Converter` rather than the project folder,
because iCloud Drive's file attributes break code signing. The app is signed
to run locally (ad hoc); it isn't notarized.

## Project layout

- `Packages/ConverterCore`: the conversion engine, a Swift package with no
  UI code, plus `converter-cli` and the core tests.
- `Converter/App`: the menu bar app (SwiftUI and AppKit): the wheel, menus,
  job queue, settings, crop editor, metadata window and file actions.
- `Converter/QuickAction`: the Finder Quick Action extension.
- `Converter/AppTests`: the app's tests.
- `docs/`: the [plan](docs/plan.md), the
  [verification report and feature table](docs/verification.md), and the
  [design notes](docs/design.md) for macOS 26 and 27.
