# Converter: plan

Working name: **Converter** (placeholder until you pick a name). A native,
fully offline macOS menu bar app that converts files by Shift-dragging them
onto a radial menu of output formats. It's inspired by the feature
description of an existing product, but none of its code, assets, name or
branding are used.

- Platform: Apple silicon only (`arm64`), macOS 13 Ventura or later.
- Build host (probed 2026-10-19): Apple M5, macOS 26.6.2, Xcode 27.1,
  Swift 6.4, xcodegen 2.46. `xcode-select` currently points at the Command
  Line Tools, so builds will set
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` per command
  rather than changing the system setting.

Everything marked **probed** in this document was checked on this Mac with
small test programs and the system tools (`sips`, `afconvert`, `textutil`,
`tar`, `aa`, `ditto`). Anything else comes from documentation or memory and
is marked *unverified*. On macOS 13–25 some of the probed abilities may be
missing, which is why the app decides what it offers at runtime (see
§1.7).

---

## 1. Format matrix

### 1.1 Images

**Inputs** (ImageIO can read all of these, probed): JPEG, PNG, HEIC/HEIF,
TIFF, GIF (including animated), BMP, WebP, AVIF, JPEG XL, JPEG 2000, PSD,
ICO, ICNS, TGA, OpenEXR, DDS, PBM, camera RAW (DNG, CR2, CR3, NEF, ARW,
RAF, ORF, RW2, PEF, SRW and others). SVG input works through `NSImage`
(probed on macOS 26; on older systems the app checks first).

| Output | Engine | Notes |
|---|---|---|
| JPEG | ImageIO `CGImageDestination` | Quality setting; EXIF and orientation kept or stripped |
| PNG | ImageIO | |
| HEIC | ImageIO | Hardware encoder on Apple silicon (probed) |
| AVIF | ImageIO | Writes on macOS 26 (probed); offered only when `CGImageDestinationCopyTypeIdentifiers()` lists `public.avif` |
| TIFF | ImageIO | |
| GIF | ImageIO | Animated GIF input stays animated |
| BMP | ImageIO | |
| PDF | ImageIO / Core Graphics PDF context | One page per image (animated GIF: first frame) |
| JPEG 2000 | ImageIO | Secondary ring |
| ICNS / ICO | ImageIO | Square, transparent padding. ICNS: 16, 32, 48, 128, 256, 512 (ImageIO drops 64 and 1024). ICO: 16, 32, 48, 64, 128, 256 (ImageIO writes at most 6 images). Sizes above the source's size are skipped |
| PSD, TGA | ImageIO | Secondary ring (flattened) |
| MP4 / MOV (animated GIF only) | ImageIO frames → AVAssetWriter (H.264) | |

**Apple frameworks can't handle these (probed):** WebP *encoding*, JPEG XL
*encoding*, and any vector output (SVG). There's no encoder on this
system for any of them.

### 1.2 Video

**Inputs** (AVFoundation, probed): MOV, MP4, M4V, 3GP/3G2, MTS/M2TS/TS
(AVCHD), MPEG-1/2 (`.mpg`, `.m2v`, `.vob`), DV, AVI (macOS 26 lists it, but
only some codecs work inside it; each file is checked with
`asset.load(.isReadable)` and its video tracks before anything is offered).

| Output | Engine | Notes |
|---|---|---|
| MP4 (H.264) | AVAssetExportSession, or AVAssetReader → AVAssetWriter for custom bitrate | Default video output |
| MP4 (HEVC) | AVAssetExportSession `HEVCHighestQuality` | HEVC-with-alpha preset when the source has alpha |
| MOV (H.264 / HEVC) | AVAssetExportSession | |
| MOV (ProRes 422 / 4444) | AVAssetExportSession ProRes presets | Secondary ring, for editors |
| M4V | AVAssetExportSession | Secondary ring |
| GIF (animated) | AVAssetImageGenerator → ImageIO GIF | Frame rate and width capped (default 15 fps, 640 px) |
| M4A (AAC) / WAV / AIFF / FLAC | Audio track via AVAssetReader → audio pipeline (§1.3) | The "Extract audio" tool |
| PNG / JPEG still | AVAssetImageGenerator | Poster frame at 0 s, or at the midpoint if 0 s is black (later) |

Video encoders on this machine (VideoToolbox, probed): H.264, HEVC
(including alpha, depth and disparity variants), ProRes 422/4444/XQ,
Motion JPEG, H.263. **There's no AV1, VP8 or VP9 encoder.**

**Apple frameworks can't handle these (probed):** WebM in or out
(`isPlayableExtendedMIMEType("video/webm") == false`), MKV in or out, FLV,
WMV/ASF, AVI *output*, AV1/VP9 *encoding*, MPEG-2 *encoding*. AV1 *decode*
works in MP4 (hardware on M3 and later), but VP9 decode isn't available to
AVFoundation.

### 1.3 Audio

**Inputs** (AVFoundation / AudioToolbox, probed): MP3, AAC/M4A, ALAC, WAV,
AIFF/AIFC, CAF, FLAC, Ogg (Vorbis and Opus; *unverified* on macOS 13–14,
checked at runtime), AMR, AC-3/E-AC-3, AU, W64, M4B/M4R, MP2, plus the audio
track of any readable video.

| Output | Engine | Notes |
|---|---|---|
| M4A (AAC) | AVAssetExportSession `AppleM4A`, or ExtAudioFile for bitrate control | Default audio output; bitrate setting |
| M4A (ALAC, lossless) | ExtAudioFile / AVAssetWriter | |
| WAV | AVAssetReader → AVAssetWriter (LPCM) | 16-bit or 24-bit setting |
| AIFF | AVAssetWriter (LPCM big-endian) | |
| FLAC | ExtAudioFile (`kAudioFileFLACType` + `kAudioFormatFLAC`) | Encoder probed with `afconvert -f flac -d flac`; present since macOS 10.13 |
| AAC (`.aac`, ADTS) | ExtAudioFile | Secondary ring |
| CAF | ExtAudioFile / AVAssetWriter | Secondary ring (LPCM, AAC or Opus inside) |

AudioToolbox encoders on this machine (probed): AAC (LC, HE, HE v2, ELD,
LD), ALAC, FLAC, Opus, iLBC, IMA4, µ-law/A-law, LPCM.

**Milestone 4 findings:** FLAC *inputs* are decoded by AVFoundation in whole
4608-frame blocks, so the converter trims to the length the file records
(and ExtAudioFile writes as many frames as the buffer's byte size holds,
whatever frame count it's given, so the byte size is trimmed too). ADTS
`.aac` files record neither their length nor the encoder delay, so
converting one keeps ~0.05 s of encoder delay at the start.

**Apple frameworks can't handle these (probed):**
- **MP3 encoding.** There's no `.mp3` encoder (`afconvert -f MPG3 -d .mp3`
  fails).
- **Ogg Vorbis encoding.** There's no Vorbis encoder.
- **Ogg Opus (`.opus` / `.ogg`).** The Opus encoder works into CAF, and
  AudioFile lists Ogg (`'Oggf'`, no public constant) as writable, but every
  route produces an empty file: `afconvert` and ExtAudioFile fail on dispose
  with `'pck?'`, and AudioConverter + `AudioFileWritePackets` writes 51
  packets into a 0-byte file, rejecting both the encoder's cookie and an
  RFC 7845 `OpusHead` cookie (`'chk?'`). Spike done in milestone 4: it needs
  libopus + libogg (on the engine list, not added).
- WMA, APE, and other encoders outside the table above.

### 1.4 Documents

**Text-like inputs:** TXT, RTF, RTFD, HTML, DOC, DOCX, ODT, WordML,
Web Archive, Markdown. **PDF input:** PDFKit.

| Input → Output | Engine | Notes |
|---|---|---|
| text-like → TXT, RTF, HTML, DOCX, DOC, ODT | `NSAttributedString` reading/writing, run as the system `textutil` tool in a subprocess | All probed with `textutil`. A subprocess keeps the HTML importer (which uses WebKit and must run on the main thread) away from the app's main thread, and can be cancelled |
| text-like → PDF | `textutil` → RTFD, then `NSAttributedString` + TextKit pages in a CG PDF context | **In the app target**, not ConverterCore: it needs AppKit (`cupsfilter` only handles plain text). Off the main thread; A4 or Letter by region; RTFD images kept |
| Markdown → HTML / RTF / DOCX / PDF | Foundation `AttributedString(markdown:)` → `NSAttributedString` | **Partly supported:** inline styles and headings map well; tables and code blocks only partly |
| PDF → TXT | PDFKit `PDFDocument.string` | Image-only PDFs give empty text (OCR is an optional tool, §1.6) |
| PDF → RTF | — | **Skipped:** writing RTF needs AppKit, and the result would only be approximate |
| PDF → PNG / JPEG / HEIC / TIFF | PDFKit page render → ImageIO | One image per page, in a folder `name (pages)/` beside the source; 150/300 dpi setting |
| image(s) → PDF | Core Graphics PDF context | See "Combine into PDF" in §1.6 |

**Apple frameworks can't handle these:** Pages/Numbers/Keynote, XLSX, PPTX,
EPUB, and PDF → DOCX with real layout. There's no public framework for
any of them. Out of scope for v1.

### 1.5 Archives

**Inputs:** ZIP, TAR, TAR.GZ/TGZ, TAR.BZ2, TAR.XZ, 7Z, RAR/RAR5
(extraction only), Apple Archive (`.aar`), CPIO, XAR, single-file `.gz`.

| Action | Engine | Notes |
|---|---|---|
| Extract (any input above) | `/usr/bin/tar` (bsdtar 3.5.3 / libarchive 3.7.4); `/usr/bin/aa` or `AppleArchive.framework` for `.aar`; `/usr/bin/gzip -dk` for single `.gz` | Extracts into `name/` beside the archive. A single top-level folder isn't nested twice. Paths are checked so nothing escapes the folder (zip-slip) |
| file/folder → ZIP | `/usr/bin/ditto -c -k --sequesterRsrc --keepParent` | Matches Finder's Compress, including resource forks and xattrs (probed) |
| → TAR.GZ, TAR.XZ | bsdtar `-czf`, `-cJf` | Probed |
| → 7Z | bsdtar `--format 7zip` | Probed |
| → AAR | `AppleArchive.framework` | Probed via `aa` |
| archive → other archive (e.g. RAR → ZIP) | Extract to a temp folder, then re-archive | |

All of these are system components that ship with macOS. Nothing is bundled.
Not supported: password-protected archives in v1 (they need a password
prompt), creating RAR (there's no encoder, and the format is proprietary),
and disk images (`hdiutil`, out of scope).

### 1.6 File tools

These appear as extra slices in the radial menu next to the formats.

| Tool | Applies to | Engine | Output |
|---|---|---|---|
| Resize image | images | ImageIO thumbnailing (`kCGImageSourceCreateThumbnailFromImageAlways`) | `photo (1920px).jpg`; presets 50 %, 25 %, longest side 3840/1920/1280/640, from a sub-ring |
| Compress image | JPEG/HEIC/AVIF/PNG | ImageIO lossy quality setting; PNG → HEIC/AVIF option | `photo (compressed).jpg` |
| Strip metadata | images | ImageIO with metadata removed | `photo (no metadata).jpg` |
| Compress video | video | AVAssetWriter, HEVC at a target bitrate | `clip (compressed).mp4` |
| Resize video | video | Export presets 2160p/1080p/720p/480p | `clip (720p).mp4` |
| Extract audio | video | AVAssetReader → M4A/WAV | `clip.m4a` |
| Remove audio | video | AVMutableComposition, passthrough | `clip (no audio).mov` |
| Video → GIF | video | §1.2 | `clip.gif` |
| Merge PDFs | 2+ PDFs | PDFKit | `first (merged).pdf` |
| Split PDF | PDF | PDFKit | folder `name (pages)/` with `name 1.pdf` … |
| Compress PDF | PDF | PDFKit write options (*unverified* on macOS 13), else the system Quartz filter "Reduce File Size" | `name (compressed).pdf` |
| Combine into PDF | 2+ images | Core Graphics PDF context | `first (combined).pdf` |
| Zip / Unzip | anything / archives | §1.5 | |
| *Optional:* Recognize text (OCR) | images, image-only PDFs | Vision `VNRecognizeTextRequest`, on-device | `name.txt` |

### 1.7 How the matrix is computed

`ConverterCore` holds a **registry** of `Converter`s. Each one declares its
input UTType(s) and output UTType, plus a `isAvailable` check that runs
once at launch (for example `CGImageDestinationCopyTypeIdentifiers()`
contains `public.avif`, or `AudioFormatGetProperty(EncodeFormatIDs)`
contains FLAC). The radial menu, the Open panel, Services and the CLI all
ask the registry: "what can I make from these files?" On macOS 13 that may
offer fewer outputs than on macOS 26, and nothing ever fails with
"unsupported encoder".

### 1.8 Optional engines (not included without your approval)

| Gap | Smallest fix | Size (arm64, approx.) | License | Notes |
|---|---|---|---|---|
| WebP encode | libwebp (static) | ~0.5 MB | BSD-3 | Cheapest high-value add |
| MP3 encode | LAME (dylib) | ~0.3 MB | LGPL-2.0 | MP3 patents expired in 2017; LGPL means it ships as a dylib users can replace |
| Ogg Opus / Vorbis encode | libopus + libogg (+ libvorbis) | ~0.6 MB | BSD-3 | Only if the AudioToolbox Ogg spike fails |
| JPEG XL encode | libjxl | ~3 MB | BSD-3 | |
| WebM, MKV, FLV, WMV, AVI out, VP9/AV1 encode, plus all of the above | **ffmpeg** | see below | LGPL or GPL | |

**What ffmpeg would cost:**
- **Binary size.** A static arm64 `ffmpeg` CLI built with
  `--disable-autodetect --disable-network --disable-doc --disable-ffplay
  --enable-videotoolbox --enable-audiotoolbox` plus libvpx, libopus,
  libvorbis, libdav1d, SVT-AV1 and LAME is roughly **20–35 MB**. A GPL
  build with x264/x265 adds another 15–30 MB and isn't needed, because
  VideoToolbox already encodes H.264 and HEVC (`h264_videotoolbox`,
  `hevc_videotoolbox`). These figures are *unverified* estimates. I'd
  measure the real number before you decide.
- **LGPL vs GPL.** An **LGPL-only** build (no `--enable-gpl`, no
  `--enable-nonfree`) can ship in a closed-source or paid app if ffmpeg stays
  a separate executable or dynamic libraries that users can replace. That
  means shipping the license text and the exact source and configure flags
  (or a written offer), and not forbidding reverse engineering of the ffmpeg
  part in the EULA. A **GPL** build (x264, x265, xvid, some filters) puts the
  combined work under GPL obligations if linked, and is a grey area even as
  a subprocess. Recommendation: LGPL only, run as a subprocess (`Process`)
  with `-progress pipe:1` for progress. That also keeps any crash in ffmpeg
  out of the app.
- **Notarization.** The binary has to be built from source (Homebrew
  bottles link against `/opt/homebrew` dylibs and can't be shipped), placed
  in `Contents/Helpers/`, and signed with our Developer ID, the hardened
  runtime and a secure timestamp. It needs no special entitlements. This is
  routine, but it adds a CI build step that has to be maintained.
- **Offline guarantee.** `--disable-network` removes ffmpeg's protocol
  handlers, so it can't open URLs even if given one.
- **Packaging options:** (a) a separate "Extra Formats" download that the
  app detects in `~/Library/Application Support/Converter/Engines/` and
  checks against our Team ID with `SecStaticCodeCheckValidity` before
  running; or (b) a second build flavour with ffmpeg included. Either way,
  the core app stays ffmpeg-free.

The code will have an `Engine` protocol, so ffmpeg (or libwebp, and so on)
can register extra converters later without touching the UI. **None of this
is included unless you approve it.**

---

## 2. Shift-drag design

### 2.1 Detecting a system-wide drag

macOS doesn't announce "another app started a drag". The app infers it
from three signals, none of which needs a permission prompt:

1. **Drag pasteboard.** `NSPasteboard(name: .drag).changeCount` goes up
   when any app starts a new drag session. Only `changeCount` is read, never
   the contents, so it shouldn't trigger macOS 26's pasteboard privacy
   prompt (*unverified*; see §6).
2. **Global mouse monitors.**
   `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown,
   .leftMouseDragged, .leftMouseUp])`. Apple's docs say only *key* events
   need Accessibility for global monitors, so mouse monitors should need
   no permission (checked in the milestone 3 spike).
3. **Modifier state.** `.flagsChanged` is a key event, so a global monitor
   for it needs **Accessibility** (Apple docs). To avoid asking for that,
   the app reads `NSEvent.modifierFlags` (a class property that reports
   the current system-wide modifier state without any permission) on a
   timer, and only while a drag is in progress.

**State machine (main thread, idle cost close to zero):**

```
idle ──leftMouseDown──▶ armed (remember drag changeCount)
armed ──leftMouseDragged + changeCount changed──▶ dragging
      (start a 60 Hz timer: modifierFlags, mouseLocation, pressedMouseButtons)
dragging ──Shift down──▶ menuShown (panel at the cursor)
menuShown ──Shift up, cursor outside ring──▶ dragging (panel hides)
any ──leftMouseUp or pressedMouseButtons == 0──▶ idle (timer stops, panel hides after a drop or immediately)
```

**Risk to check first in milestone 3:** while a drag session is running,
the window server may not send `.leftMouseDragged` to global monitors.
If so, step 2 becomes a low-rate (10 Hz) poll of `pressedMouseButtons`
together with the pasteboard `changeCount`, which still needs no
permission. A listen-only `CGEventTap` would be the last resort; it
needs Input Monitoring (macOS 10.15+), and the app would ask with
`CGRequestListenEventAccess()`.

### 2.2 The radial menu panel

- An `NSPanel` subclass with `styleMask: [.borderless, .nonactivatingPanel]`,
  `level = .popUpMenu`, `collectionBehavior = [.canJoinAllSpaces,
  .fullScreenAuxiliary, .transient, .ignoresCycle]`, `hidesOnDeactivate =
  false`, a clear background and a shadow. It never becomes key or main, so
  Finder keeps focus and the drag isn't interrupted.
- Shown with `orderFrontRegardless()`, centred on `NSEvent.mouseLocation`
  and clamped to the visible frame of the screen under the cursor.
  Diameter about 300 pt. The centre is a "cancel" hole: dropping there does
  nothing.
- The content view is an `NSView` registered for `.fileURL` that
  implements `NSDraggingDestination`:
  - `draggingEntered`: now the app legitimately has the drag's pasteboard.
    It reads the file URLs, groups them by UTType, asks the registry for
    outputs, and lays out the slices (formats first, then a "Tools" slice
    that opens a sub-ring). Because the panel appears *under* the cursor,
    the next mouse movement enters it, and the slices fill in within one
    frame. Until then the ring shows a neutral "Reading…" state.
  - `draggingUpdated`: hit-tests the angle and radius and highlights the
    slice. Hovering about 400 ms on "Tools" or "More" opens an outer
    ring (spring-loading).
  - Returns **`.copy`** so Finder never moves or deletes the source.
  - `performDragOperation`: queues the chosen conversion for every dropped
    file and returns `true`; then the panel fades out.
- Rendering: SwiftUI inside `NSHostingView` for the slices (icons and
  labels), while hit-testing and drag handling stay in the AppKit view.
  The look is our own, not modelled on any existing app.
- Mixed selections (for example 3 JPEGs and a PDF): the ring shows only
  the outputs common to all of them. If there are none, it shows one slice
  per kind ("Images → …", "PDF → …").

### 2.3 Permissions

| Feature | Permission | How it's requested |
|---|---|---|
| Shift-drag (planned path) | **None** | — |
| Shift-drag fallback (only if the milestone 3 spike shows it's needed) | Input Monitoring (listen-only event tap) or Accessibility (`flagsChanged`) | An onboarding window explains why, then `CGRequestListenEventAccess()` / `AXIsProcessTrustedWithOptions([prompt: true])`, plus a button that opens the right Privacy & Security pane |
| Writing beside the original | None (not sandboxed). Files in Desktop/Documents/Downloads, iCloud Drive or removable volumes trigger macOS's one-time folder access prompts | Prompted by macOS the first time; the app shows a clear error if denied |
| Notifications | User Notifications (optional) | Asked the first time a long conversion finishes |

**If a needed permission is denied:** the gesture turns itself off, the menu
bar menu shows "Shift-drag needs permission… Enable", and every other entry
point (§3) keeps working.

### 2.4 Signing and distribution

- **No Mac App Store.** The sandbox blocks this design in two ways: a
  sandboxed app can't write a new file beside a dragged-in original (a drop
  grants access to the file, not its folder), and it can't watch drags and
  modifier keys across the whole system.
- **Developer ID + hardened runtime + notarization.** Signed with a
  Developer ID Application certificate, notarized with `notarytool`, stapled,
  and shipped as a DMG or ZIP. The hardened runtime needs no exception
  entitlements (Apple frameworks plus system binaries in `/usr/bin`).
- **Local development:** signed with a stable *Apple Development*
  identity, not ad hoc. macOS ties permission and folder-access grants to
  the code signature, so ad-hoc builds lose them on every rebuild.
- **Updates:** there's no auto-update in v1, because an updater (such as
  Sparkle) needs the network. Users update manually.

---

## 3. Fallback entry points

1. **Drop onto the menu bar icon.** `NSStatusItem` (not SwiftUI
   `MenuBarExtra`, which can't take drops) with a transparent drag
   destination subview on its button. Dragging over the icon opens the same
   radial panel just below it, and the user drops on a format. Dropping on
   the icon itself opens a regular `NSMenu` of formats at the icon.
2. **Open panel.** The menu bar menu has "Convert Files…": an `NSOpenPanel`
   (multiple selection), then a format sheet with the same registry entries
   as buttons.
3. **Services menu.** The main app's `Info.plist` declares `NSServices`
   with `NSSendFileTypes` per kind ("Convert with Converter…"). That shows
   up in Finder's right-click > Services, needs no extension and no
   sandbox, and opens the format picker at the
   cursor.
4. **Finder Quick Action (milestone 6).** An Action Extension
   (`com.apple.services`, `NSExtensionServiceAllowsFinderPreviewItem`)
   shows up in Finder's Quick Actions menu and preview pane. App extensions
   *must* be sandboxed, so the extension never converts anything itself. It
   passes the file URLs to the main app (`NSWorkspace.open(_:withApplicationAt:)`),
   which shows the picker and writes the output.
5. **Command line.** `converter-cli` (from milestone 1) for testing and
   power users: `converter-cli photo.heic --to jpeg`.

---

## 4. Project layout

```
Converter/                      xcodegen project.yml → Converter.xcodeproj (checked in)
  App/                          SwiftUI + AppKit, LSUIElement = YES (no Dock icon)
    StatusItemController.swift  NSStatusItem, drop target, menu
    DragWatcher.swift           §2.1 state machine
    RadialPanel/                NSPanel, slice layout, hit-testing
    JobQueue.swift              Concurrent jobs, progress, cancel
    Settings/                   SwiftUI settings window, SMAppService login item
  QuickAction/                  Action Extension (milestone 6)
Packages/ConverterCore/         Swift package, no AppKit/SwiftUI imports
  Sources/ConverterCore/        Registry, Converter protocol, OutputNamer, engines
  Sources/converter-cli/        CLI
  Tests/ConverterCoreTests/     XCTest: every pair in the matrix
docs/plan.md
```

**Job contract** (every converter, every entry point):
- Runs in a Swift `Task` off the main thread. CPU-heavy image work is
  limited to about the number of performance cores.
- Reports progress through a `Progress`/`AsyncStream<Double>`. The UI shows
  a ring on the menu bar icon, a list in the menu with per-job Cancel, and an
  optional notification when done.
- Cancellation goes through `Task.cancel()`: `AVAssetExportSession.cancelExport()`,
  `Process.terminate()` for `ditto`/`tar`/`textutil`, and
  `Task.checkCancellation()` between frames and pages.
- **No partial files:** output is written into a temporary directory on
  the *same volume* (`FileManager.url(for: .itemReplacementDirectory, …)`).
  On success it's moved into place with an exclusive rename
  (`renamex_np(RENAME_EXCL)`), so it can never overwrite an existing file,
  and the name is retried as `photo 2.jpg`, `photo 3.jpg`… if taken. On
  failure or cancel, the temp directory is deleted. The original is opened
  read-only and never written.
- **Output names:** `photo.heic` → `photo.jpg`; if that exists, `photo 2.jpg`,
  then `photo 3.jpg` (Finder style). Tools add a short suffix
  (`photo (1920px).jpg`). Multi-file outputs go into a folder named the same
  way.
- **Offline:** ConverterCore and the app don't link `Network.framework` or
  use `URLSession`. A test checks the built binary's imported symbols
  (`nm -u`) to make sure that stays true.

---

## 5. Milestones

Each milestone ends with a working build and passing tests before the next
one starts.

| # | Deliverable | Done when |
|---|---|---|
| 1 | `ConverterCore`: registry, job contract, OutputNamer, all image converters (§1.1) and image tools (resize, compress, strip metadata); `converter-cli` | XCTests convert every image pair and check UTType, pixel size and frame count; the "no partial file on cancel or failure" tests pass |
| 2 | Menu bar app: status item, drop onto the icon → format menu, Open panel, job list with progress and cancel | Dropping a HEIC on the icon creates `name.jpg` beside it; a second drop creates `name 2.jpg` |
| 3 | **Shift-drag radial menu**: run the §2.1 spike first, then build the panel | Dragging from Finder with Shift shows the ring at the cursor, dropping on a slice converts, Finder doesn't move the file, and no permission prompt appears (or the fallback is documented) |
| 4 | Video, audio, document and archive converters (§1.2–1.5), plus the Ogg spike | XCTests for every pair check duration (±0.1 s), track types, page count and archive contents |
| 5 | File tools (§1.6) and a settings window: per-format quality, default format order per kind, metadata on/off, launch at login (`SMAppService.mainApp`), Shift-drag on/off | Settings persist and change the output; the login item survives a reboot |
| 6 | Services menu entries and a Finder Quick Action extension | Right-click > Quick Actions > Converter opens the picker and the output appears beside the file |
| — | Test and verify: generated samples, full XCTest suite, a manual Shift-drag run, and a feature table (built / partly built / skipped) | |

**Progress**
- **Milestone 1: done (2026-10-19).** `ConverterCore` with 13 image formats,
  animated image → MP4/MOV, resize (6 presets), compress and strip metadata;
  `converter-cli`; 28 XCTests, including 209 format pairs across 17
  generated input kinds. Build with `make core-test` (output goes to
  `~/Library/Caches/Converter`, because iCloud sync of `~/Documents` breaks
  code signing). SVG input is deferred to milestone 2 (see §7).
- **Milestone 2: done (2026-10-19).** Menu bar app (`Converter/`, generated
  by xcodegen) with a drop target on
  the status item, a format picker (main formats, More Formats, Resize and
  other tools), Convert Files… (Open panel), Open With / drop on the app
  icon, a job list with progress, Cancel and Show in Finder, a progress
  ring on the icon, quit-while-converting handling, and SVG input through
  an AppKit rasterizer plugged into the core. 13 app XCTests plus 29 core
  tests. A drop from Finder onto the icon was checked by hand: photo.jpg,
  then photo 2.jpg, both in the job list.
- **Milestone 3: built; a real Shift-drag test is pending (2026-10-19).**
  `DragWatcher` (global mouse-down monitor plus 60 Hz polling of buttons, drag
  pasteboard `changeCount`/types and Shift, only while the button is held),
  so no permission prompt is involved. `RadialPanel` is a borderless,
  non-activating panel with a Canvas-drawn ring: the same entries as the
  picker, sub-rings for "More Formats" and "Resize" after a 250 ms dwell,
  the output name in the centre, and the centre as cancel. Drops are always
  a copy. There's an on/off item in the menu, and gesture steps are logged
  to the `com.example.Converter` / `shift-drag` log. 35 app tests (watcher
  replayed through a fake environment, geometry, model, synthetic drops,
  offscreen snapshots) plus 29 core tests. You confirmed it by hand: the
  ring, a drop on JPEG, Resize 50 % and a cancel in the centre all worked,
  and the log showed each step.
- **Milestone 4: done (2026-10-19).** Video: MP4 (H.264), MP4 (HEVC), MOV,
  MOV (ProRes), M4V, GIF, an "Audio" group (M4A, WAV, AIFF, FLAC) and Save
  Frame. Audio: M4A (AAC), M4A Lossless, WAV, AIFF, FLAC, AAC (ADTS) and
  CAF, keeping 24-bit depth and exact lengths. Documents: Plain Text, RTF,
  HTML, Word, Word 97 and OpenDocument with `textutil`, plus PDF from the
  app. PDF → text, and PDF → PNG/JPEG/HEIC/TIFF (one image per page, in a
  folder for several pages). Archives: Extract (ZIP, TAR, TAR.GZ/BZ2/XZ, 7Z,
  RAR, AAR, CPIO, XAR, .gz/.bz2), convert between archive formats, and an
  "Archive" group (ZIP, TAR.GZ, TAR.XZ, 7Z, Apple Archive), with several
  files making one `Archive.zip`. At most one video job runs at a time.
  Tests: 39 core (209 image pairs plus 247 media/document/archive pairs) and
  42 app. The Ogg Opus spike failed (§1.3).
- **Milestone 5: done (2026-10-19).** File tools: Compress video (HEVC at
  a bit rate from size × frame rate × level; reports instead of saving when
  the result isn't ≥ 5 % smaller), Resize video to 4K/1080p/720p/540p
  (never enlarges), Remove Audio (picture copied without re-encoding),
  Merge PDFs and Combine into PDF (2+ files, in name order), Split Pages,
  Compress PDF (PDFKit JPEG + screen resolution, macOS 13.4+), and Recognize
  Text (Vision, on-device) for images and PDFs. Extract audio, video → GIF,
  and zip/unzip came with milestone 4. Settings window (⌘,): open at login
  (`SMAppService.mainApp`), the Shift-drag switch, showing results in
  Finder, a favourite format per kind (listed first in the menu and at 12
  o'clock on the ring), image quality, compression and metadata, video
  compression level, GIF frame rate and size, AAC bit rate, and PDF render
  resolution. All saved in UserDefaults and applied to new jobs. Tests: 47
  core (including 270 media/document/archive pairs) and 49 app. **Not
  checked here:** turning launch at login on for real, which adds a login
  item to this Mac, so the tests use a stand-in.
- **Milestone 6: done (2026-10-19).** You confirmed Services, the Quick
  Action and Open With in Finder. Services: "Convert with Converter…" (`NSServices`, any file or
  folder, enabled by default) shows the format menu at the pointer.
  Quick Action: `ConverterQuickAction.appex` (`com.apple.services`,
  sandboxed, Finder context menu and preview pane) passes the selection to
  the app with `NSWorkspace.open(_:withApplicationAt:)`, and the app shows
  the menu at the pointer. "Open With" and drops on the app icon now use
  the pointer too. Verified here: `pbs` lists the service, `pluginkit` lists
  the extension, and invoking the service through `NSPerformService` with
  the debug-only `DebugAutoPickConverter` default converted photo.heic →
  photo 3.jpg with no UI. Not verified: the extension can't be invoked
  without Finder, so you tested it by hand. 55 app tests and 47 core tests.
- **Three rings (2026-10-19, after the milestones).** At your request,
  the wheel now works like the public description at tangerineformac.com.
  - Start dragging, then *tap* ⇧ for Convert formats, ⌘ for File tools or ⌃
    for File actions. Keys held when the drag starts don't count.
  - Another key, or scrolling (one ring per trackpad swipe or wheel notch),
    switches rings. The wheel stays open until the drop.
  - The keys can be changed in Settings; choosing one that's in use swaps
    the two.
  - The six file actions (AirDrop, Float shelf, Copy, Move…, Copy Path,
    Terminal) are in the wheel and in every menu picker, for any file or
    folder.
  - While ⌘ or ⌃ is held, macOS only allows a generic or link drop, so the
    wheel accepts those instead of refusing, and never a move.
  - The site also says the real app is sold on the **Mac App Store**, so the
    sandbox may be workable after all (§2.4 assumed it wasn't). Revisit
    before distribution.
- **Test and verify: done (2026-10-19).** A clean rebuild passes 104 tests
  (47 core, 57 app). The Release build was checked. The full feature table
  is in [verification.md](verification.md).

Sample files are generated, never downloaded: `sips` (images), `afconvert`
(audio), `textutil` (documents), `AVAssetWriter` code (video with known
duration and size), `tar`/`ditto` (archives), and PDFKit (multi-page PDFs).

## 6. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Global mouse monitors don't receive events during another app's drag session | The gesture can't be detected | Poll `pressedMouseButtons` and the drag `changeCount` (no permission), or a listen-only event tap (Input Monitoring). This is the first thing milestone 3 checks |
| The panel doesn't get `draggingEntered` until the mouse moves after it appears | Slices fill in late or not at all | Show the panel slightly offset so the next mouse movement crosses into it; this should work but it's *unverified* |
| macOS 26 pasteboard privacy also covers the drag pasteboard | A privacy prompt on every drag | Only `changeCount` is read before the drop; contents are read inside `draggingEntered`, which macOS treats as user-initiated |
| Features found on macOS 26 are missing on macOS 13 (AVIF write, Ogg read, SVG via NSImage, AVI read) | Fewer formats on older systems | Runtime probes (§1.7). I can only test on macOS 26 here, so **testing on macOS 13–15 needs a VM or another Mac** |
| The HTML importer needs the main thread | UI stalls on large HTML | Run through the `textutil` subprocess |
| Large videos: long exports, thermal throttling | User waits a long time | Hardware encoders; progress and cancel; one video job at a time by default |
| Files in iCloud Drive that aren't downloaded yet | Read fails or stalls | Use `NSFileCoordinator` / `startDownloadingUbiquitousItem` before reading |
| Folder-access prompts (Desktop, Downloads, removable volumes) | The first conversion in a folder asks for permission | Expected macOS behaviour; the error message explains it |
| Apple can change drag behaviour in a macOS update | The gesture breaks | Drop-on-icon, Services and Quick Action don't depend on it |
| Code signing identity | Notarization needs a Developer ID (paid Apple Developer Program) | See question 2 below |

## 7. Decisions (approved 2026-10-19)

1. **Optional engines:** none for now. Apple frameworks and system tools
   only. The `Engine` hook stays, so one can be added later with approval.
2. **Signing:** "Sign to Run Locally" (ad hoc) during development. Expect
   macOS folder-access and permission grants to reset after rebuilds. No
   notarization until a Developer ID is available.
3. **Trigger key:** Shift only. No setting to change it.
4. **Test scope:** macOS 26 on this Mac is enough. Older systems rely on
   the runtime capability checks in §1.7 and aren't tested here.
5. **SVG input** needs `NSImage` (AppKit), which `ConverterCore` must not
   import. It moves to the app target as a decoder plugged into the core
   (milestone 2).
