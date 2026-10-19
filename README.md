<div align="center">

<img src="docs/images/icon.png" width="112" alt="">

# File converter for Mac

**Drag a file, tap a key, drop it on the wheel.**<br>
Convert, crop, compress, inspect and share files on your Mac without uploading them anywhere.

[![macOS 13 or later](https://img.shields.io/badge/macOS-13%2B-1d1d1f?logo=apple&logoColor=white)](#building)
[![Apple silicon](https://img.shields.io/badge/Apple%20silicon-arm64-1d1d1f)](#building)
[![Fully offline](https://img.shields.io/badge/network-none-2ea44f)](#private-by-design)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](#project-layout)

### [▶ Try the wheel in your browser](https://jonathanlotan.github.io/File-converter-for-mac/)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/wheel-demo.dark.gif">
  <img src="docs/images/wheel-demo.light.gif" width="460" alt="Animation: while a photo is dragged, the wheel opens with formats, scrolling switches to Actions and then Tools, and dropping on Crop › Square saves a square copy next to the original.">
</picture>

</div>

## One gesture, three rings

Start dragging files anywhere, in Finder or on the desktop, and **tap** a key.
The wheel opens at the pointer. Drop on a slice to run it, or in the middle to
cancel. Slices marked › open a second ring when you rest on them.

<table>
  <tr>
    <th align="center"><kbd>⇧</kbd> Shift: <b>Convert</b></th>
    <th align="center"><kbd>⌘</kbd> Command: <b>Tools</b></th>
    <th align="center"><kbd>⌃</kbd> Control: <b>Actions</b></th>
  </tr>
  <tr>
    <td>
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/wheel-convert.dark.png">
        <img src="docs/images/wheel-convert.light.png" alt="The Convert ring for a HEIC photo, pointing at JPEG: the middle says IMG_2041.jpg">
      </picture>
    </td>
    <td>
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/wheel-tools.dark.png">
        <img src="docs/images/wheel-tools.light.png" alt="The Tools ring with Crop open, pointing at Square">
      </picture>
    </td>
    <td>
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/wheel-actions.dark.png">
        <img src="docs/images/wheel-actions.light.png" alt="The Actions ring with Share open, pointing at Mail">
      </picture>
    </td>
  </tr>
  <tr>
    <td valign="top">The formats these files can become: images, video, audio, documents and PDFs. Less common ones are under More.</td>
    <td valign="top">Resize, crop, compress, remove metadata, recognize text, merge or split PDFs, make archives.</td>
    <td valign="top">Share (AirDrop, Mail, Messages, Notes, Photos, or any app), see metadata, float on a shelf, copy, move, copy the path, open in Terminal.</td>
  </tr>
</table>

- **Scroll** to switch rings. Up goes to the next one, in the order Actions, Tools, Convert. Tapping another key works too.
- **Results go next to the original**, named the way Finder would: `IMG_2041.jpg`, `IMG_2041 2.jpg`, `IMG_2041 (square).heic`. Nothing is ever overwritten, and the original is never changed.
- **The keys are yours to choose** in Settings. Keys already held when a drag starts don't count, so ordinary drags behave as before.

## Crop and metadata

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/crop-editor.dark.png">
  <img src="docs/images/crop-editor.light.png" width="760" alt="The crop editor: a landscape photo with a 4:3 crop, an Aspect menu, width and height fields, and Reset, Skip, Cancel and Crop & Next buttons">
</picture>

**Crop** has Square, 4:3, 3:2, 16:9, 3:4, 2:3 and 9:16 straight from the wheel, cut from the
middle. **Custom…** opens the editor above: drag the handles, pick a shape, or type an exact
size and the crop is scaled to it. With several photos it steps through them, keeping the shape.

<table>
  <tr>
    <td width="50%" valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/metadata.dark.png">
        <img src="docs/images/metadata.light.png" alt="The metadata window for a photo: camera, lens, exposure, date taken, and location coordinates, with Remove Metadata and Copy All buttons">
      </picture>
    </td>
    <td width="50%" valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/settings.dark.png">
        <img src="docs/images/settings.light.png" alt="The General settings: which key opens each ring, the menu bar icon, launch at login and the terminal app">
      </picture>
    </td>
  </tr>
  <tr>
    <td valign="top"><b>Metadata</b> shows what a file says about itself: camera, lens, exposure and location for photos; tracks and codecs for audio and video; pages and author for PDFs. <b>Remove Metadata</b> saves a clean copy.</td>
    <td valign="top"><b>Settings</b>: the keys for each ring, image and video quality, favourite formats, launch at login, and whether the menu bar icon shows.</td>
  </tr>
</table>

## What it handles

<details>
<summary><b>Images</b>: JPEG, PNG, HEIC, AVIF, TIFF, GIF, PDF and more</summary>

- Write: JPEG, PNG, HEIC, AVIF, TIFF, GIF, PDF, BMP, JPEG 2000, ICNS, ICO, PSD, TGA.
- Also read: WebP, EXR and SVG. JPEG XL and camera RAW should open too, through macOS, but aren't tested.
- Animated GIFs can become MP4 or MOV.
- Tools: resize, crop, compress, remove metadata, recognize text, combine into a PDF.
- Photos stay upright, and their metadata is kept unless you turn that off.
</details>

<details>
<summary><b>Video and audio</b>: MP4, MOV, ProRes, GIF, M4A, WAV, FLAC…</summary>

- Video: MP4 (H.264 or HEVC), MOV, MOV (ProRes), M4V, GIF, or a still frame.
- The sound from a video: M4A, WAV, AIFF or FLAC.
- Audio: M4A (AAC or lossless), WAV, AIFF, FLAC, AAC, CAF. 24-bit stays 24-bit.
- Tools: compress, resize to 4K, 1080p, 720p or 540p, remove audio.
</details>

<details>
<summary><b>Documents and PDFs</b>: Word, RTF, HTML, text, PDF</summary>

- Between plain text, RTF, HTML, Word (.docx and .doc) and OpenDocument, and any of them to PDF.
- PDF to text, or to PNG, JPEG, HEIC or TIFF pages.
- Merge, split and compress PDFs, and recognize text in scans.
</details>

<details>
<summary><b>Archives</b>: ZIP, TAR.GZ, TAR.XZ, 7Z, Apple Archive</summary>

- Make an archive of any files or folders, extract one, or convert between formats.
- Extracting never writes outside its own folder.
</details>

Formats that would need third-party encoders (writing WebP or JPEG XL, MP3, Ogg, WebM, MKV)
aren't included.

**Other ways in:** drop files on the menu bar icon, choose **Convert Files…** from its menu,
use **Services › Convert with Converter…** or the Quick Action in Finder, or **Open With**.

## Private by design

Everything happens on your Mac, with Apple's own frameworks (ImageIO, AVFoundation,
AudioToolbox, PDFKit, Vision) and tools that come with macOS (`textutil`, `ditto`, `tar`,
`aa`). There's no network code, no account and no telemetry; a test checks that no
networking APIs are linked. Locations in the metadata window are shown as coordinates,
with no map, because a map would need the network.

## Building

You need Xcode 26 or later (built and tested with Xcode 27.1) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
make run
```

| Command | What it does |
|---|---|
| `make run` | Builds and opens the app (it lives in the menu bar) |
| `make test` | Runs all tests: 64 for the conversion engine, 102 for the app |
| `make app` | Generates the Xcode project and builds the app |
| `make core-test` | Runs only the conversion engine's tests |
| `make cli` | Builds `converter-cli` and prints its path |
| `make readme-images` | Renders the pictures on this page from the app's own views |
| `make clean` | Removes the build output |

Builds go to `~/Library/Caches/Converter` rather than the project folder, because iCloud
Drive's file attributes break code signing. The app is signed to run on your own Mac (ad
hoc); it isn't notarized.

## Project layout

- `Packages/ConverterCore`: the conversion engine, a Swift package with no UI code, plus `converter-cli` and its tests.
- `Converter/App`: the menu bar app in SwiftUI and AppKit: the wheel, menus, job queue, settings, crop editor, metadata window and file actions.
- `Converter/QuickAction`: the Finder Quick Action extension.
- `Converter/AppTests`: the app's tests, including the renderer for this page's pictures.
- `docs/`: the [plan](docs/plan.md), the [verification report and feature table](docs/verification.md), the [design notes](docs/design.md) for macOS 26 and 27, and the [browser tryout](docs/index.html).
