# Converter: verification report

Date: 2026-10-19. Build: 0.2.0, Apple M5, macOS 26.6.2, Xcode 27.1.
Plan and decisions: [plan.md](plan.md).

## Summary

- All six milestones are built.
- A clean rebuild passed **104 automated tests**: 47 in `ConverterCore` and
  57 in the app. After the three-ring change, 125 pass (47 + 78). With
  sharing, cropping and metadata added, **166 pass (64 + 102)**; two more
  app tests only render the README's pictures and are skipped unless
  `make readme-images` runs them. Together they convert **479 file pairs** (209 image pairs
  plus 270 video, audio, document, PDF and archive pairs) and run the tools
  on purpose-made samples. The per-pair results are in
  [test-reports/](test-reports/).
- You checked the parts that need Finder by hand: dropping on the menu bar
  icon, the Shift-drag ring, Services, the Quick Action and Open With. I
  matched the Shift-drag test against the app's log.
- **Not verified:**
  - turning on launch at login for real, which would add a login item to this Mac
  - the Convert Files… panel, the progress ring on the icon, Show in Finder,
    and quitting during a conversion (not checked by hand)
  - macOS 13 to 25 (your decision 4)
  - Share, the crop editor and the metadata window, by hand (their logic,
    saving and layout are tested; the system share sheet and real
    dragging in the editor aren't)
  - Developer ID signing and notarization (no Developer ID yet)

## How it was tested

### Automated (`make test`, 76 s from a clean build)

| Suite | Tests | What it checks |
|---|---|---|
| ImageMatrixTests | 2 | 17 generated image kinds × every image output: 209 pairs. Checks the output type, size, frame and page count, icon sizes, and the length of video made from GIFs |
| ImageBehaviourTests | 18 | EXIF orientation applied, transparency (white in JPEG, kept in HEIC), metadata kept or removed (removal without re-encoding), resize, compress, the SVG rasterizer hook, AVIF only where it can be encoded |
| MediaMatrixTests | 1 | 25 generated samples × every single-file converter: 270 pairs. Video: codec, length, size and sound. Audio: codec, bit depth and exact length. Documents: text survives. PDFs: pages. Archives: the file tree. 22 expected refusals or declines (for example, no sound in a silent clip) |
| MediaBehaviourTests | 9 | Archive naming and nesting, path-escape safety, "same format" rules, exact FLAC length, a silent video, a scanned PDF, cancelling a video export |
| FileToolTests | 8 | Compress video (a noisy clip shrinks to under half, as HEVC), resize to 540p, merge PDFs in name order, compress an image-heavy PDF, combine images, recognize text |
| JobRunnerTests | 8 | Finder-style names, never overwriting, original untouched, nothing left behind on failure or cancel, read-only folders, batches |
| OfflineTests | 1 | The CLI uses no networking APIs |
| CropTests | 9 | Centred aspect regions, keeping regions inside the image, upright pixels for rotated photos, exact output sizes, metadata and transparency kept, animations cropped frame by frame, presets hidden when the image already has that shape |
| MetadataTests | 8 | Camera, exposure, lens and GPS fields from EXIF; orientation; no empty sections; video and audio tracks; PDF info; folders; the download source; text for copying |
| App: radial menu | 13 | Ring geometry, slice and sub-ring hit-testing, the menu model, drops at slice positions, dwell to open a group |
| App: drag watcher | 8 | Shift-drag detection replayed through a fake mouse, pasteboard and modifier source |
| App: settings | 7 | Saving settings, launch at login (enabled, waiting for approval, failure) through a stand-in, the favourite format first, every tab rendered |
| App: milestone 4 | 7 | Rich text → PDF for all six text formats and long documents, one job per combined archive, one video job at a time, folder and video menus |
| App: Finder | 6 | The Services handler, the Info.plist declarations, the extension's activation rule, how it finds the app and reads Finder's files |
| App: job queue | 5 | Results beside the original, the concurrency limit, cancelling, failures, clearing |
| App: crop editor | 9 | Handles with and without a fixed shape, moving, limits, typing an exact size, Crop & Next keeping the shape, Skip and Cancel, saving through the queue, Custom… opening the editor instead of running, a layout render |
| App: metadata window | 5 | Sections and summary, Remove Metadata only for tagged images, stepping through a selection, Copy All, a layout render |
| App: file actions | 12 | Copy, Copy Path, Move…, Terminal, Float; Share services through a stand-in; More… and Metadata hand-offs; which services are offered; the menus' Actions section |
| App: other | 11 | Format menu (3), menu bar drop target (3), SVG rendering (2), offline check for the app and extension (2), ring snapshots (1) |

### By hand

| Check | Done by | Result |
|---|---|---|
| Drop a HEIC on the menu bar icon, choose JPEG, twice | you | `photo.jpg`, then `photo 2.jpg`; both in the job list |
| Shift-drag from Finder: ring at the pointer, JPEG, Resize 50 %, drop in the centre | you; I read the log | All worked. The log showed each step, and a non-file drag was ignored |
| Services, Quick Action and Open With from Finder's context menu | you | The menu appeared at the pointer and the file converted |
| Services path without the UI (`NSPerformService` with the debug-only auto-pick) | me | `photo 3.jpg` created |
| Release build | me | 1.8 MB, arm64 only, no Dock icon, macOS 13 minimum, no debug hook, no networking symbols, ad-hoc signature verifies |
| Ring and settings layout | me, offscreen renders | Labels fit in light and dark mode. I fixed a label clash at 12 slices |

I couldn't run the Shift-drag test myself, because Finder control was
declined for this session, so that test is yours. The Quick Action
extension can't be run without Finder.

## Feature table

Status: **Built**, **Partly built** or **Skipped**. "Verified" says how.

| Area | Feature | Status | Verified | Notes |
|---|---|---|---|---|
| Images | Read JPEG, PNG, HEIC/HEIF, TIFF, GIF, BMP, WebP, AVIF, JPEG 2000, PSD, ICO, ICNS, TGA, EXR | Built | Automated | WebP only as tiny public test images: there's no WebP encoder to make bigger ones |
| Images | Read SVG | Built | Automated | Rendered by AppKit in the app and passed into the core |
| Images | Read JPEG XL, camera RAW, DDS, PBM | Built | Not tested | ImageIO reads them like the rest; macOS can't make JPEG XL or RAW samples |
| Images | Write JPEG, PNG, HEIC, AVIF, TIFF, GIF, PDF, BMP, JPEG 2000, ICNS, ICO, PSD, TGA | Built | Automated | AVIF only where ImageIO can encode it. ICO holds at most 6 sizes, and ICNS has no 64 or 1024 px (ImageIO limits) |
| Images | Animated GIF/APNG/WebP → MP4 or MOV | Built | Automated | |
| Images | Write WebP or JPEG XL | Skipped | — | No Apple encoder; libwebp or libjxl need your approval |
| Video | MP4 (H.264), MP4 (HEVC), MOV, MOV (ProRes), M4V | Built | Automated | |
| Video | Video → GIF, Save Frame | Built | Automated | |
| Video | Sound → M4A, WAV, AIFF, FLAC | Built | Automated | |
| Video | Read AVI, MPEG-2, MTS | Built | Not tested | Offered whenever AVFoundation reads the file; codecs inside AVI vary |
| Video | WebM, MKV, FLV, WMV, AVI output, AV1/VP9 encoding | Skipped | — | Not supported by Apple's frameworks; would need ffmpeg (not approved) |
| Audio | M4A (AAC), M4A Lossless, WAV, AIFF, FLAC, AAC (ADTS), CAF | Built | Automated | Keeps 24-bit depth and the source's exact length |
| Audio | Read MP3 and Ogg | Built | Not tested | AVFoundation reads them on macOS 26; there's no encoder here to make samples |
| Audio | Write MP3, Ogg Vorbis, Ogg Opus | Skipped | — | No Apple encoder. The Ogg Opus spike produced only empty files. Would need LAME or libopus |
| Documents | TXT, RTF, HTML, Word (.docx, .doc), OpenDocument, between each other | Built | Automated | `textutil` in a subprocess |
| Documents | Text document → PDF | Built | Automated | In the app, not `ConverterCore`, because it needs AppKit; not available in the CLI |
| Documents | Markdown | Partly built | Automated | Read as plain text: headings and emphasis aren't formatted |
| Documents | PDF → text; PDF → PNG, JPEG, HEIC, TIFF | Built | Automated | Several pages become a folder |
| Documents | PDF → RTF | Skipped | — | Writing RTF needs AppKit, and the layout would only be approximate |
| Documents | Pages, Numbers, Keynote, XLSX, PPTX, EPUB | Skipped | — | Outside the plan; no public framework |
| Archives | Extract ZIP, TAR.GZ, TAR.XZ, 7Z, Apple Archive, .gz | Built | Automated | Never writes outside the output folder; a lone top folder isn't nested twice |
| Archives | Extract RAR, TAR.BZ2, CPIO, XAR, .bz2 | Built | Not tested | Same `tar` path; no RAR encoder to make samples |
| Archives | Create ZIP, TAR.GZ, TAR.XZ, 7Z, Apple Archive | Built | Automated | Several files become `Archive.zip`; ZIPs match Finder's Compress |
| Archives | Convert between archive formats | Built | Automated | |
| Archives | Password-protected archives | Skipped | — | Needs a password prompt |
| File tools | Resize, compress, remove metadata (images) | Built | Automated | |
| File tools | Compress video, resize video, remove audio, extract audio, video → GIF | Built | Automated | Won't save a compressed video that isn't smaller, or enlarge one |
| File tools | Merge PDFs, split PDF, compress PDF, combine images into PDF | Built | Automated | Compress PDF needs macOS 13.4 |
| File tools | Recognize text (OCR) | Built | Automated | Vision, on this Mac |
| File tools | Crop: Square, 4:3, 3:2, 16:9, 3:4, 2:3, 9:16 from the centre | Built | Automated | Not offered when the image already has that shape. Upright, metadata kept, every frame of an animation |
| File tools | Crop › Custom…: crop editor (drag handles, aspect ratio, exact output size, steps through a selection) | Built | Automated; **not tried by hand** | An exact size scales the crop to that many pixels |
| File tools | Zip, unzip | Built | Automated | |
| Wheel | Detect file drags and modifier taps without permissions | Built | By you (Shift), plus the log | No Accessibility or Input Monitoring prompt |
| Wheel | Three rings: tap ⇧ Convert, ⌘ Tools, ⌃ Actions; another key or scrolling switches; open until the drop | Built | Automated, and by you (before scrolling was reversed) | Keys held as the drag starts don't count. Ring order: Actions, Tools, Convert; scrolling up goes to the next ring |
| Wheel | Ring contents: slices, sub-rings, output name, centre cancels | Built | Automated, and by you (Convert ring) | |
| Wheel | Drops while ⌘ or ⌃ is held | Built | Automated (simulated) | Accepted as generic or link, never as a move |
| Wheel | Choose the keys in Settings | Built | Automated | Choosing a key that's in use swaps the two |
| Wheel | Permission fallback (event tap, Accessibility) | Skipped | — | Not needed: the route without permissions worked |
| Wheel | On/off switch | Built | Automated | Menu bar menu and settings |
| File actions | Copy, Copy Path, Move… (never replaces), Terminal | Built | Automated (pasteboard, picker and launching swapped out) | |
| File actions | Float shelf (drag out, drop in, pin to edge) | Built | Not tried by hand | |
| File actions | Share: AirDrop, Mail, Messages, Notes, Photos, More… (system share picker) | Built | Automated with a stand-in service; **not tried by hand** | Missing services are left out. Notes has no public service name, so its extension's identifier is used. The menus use the system's Share… item |
| File actions | Metadata window: file details, camera, exposure, location and caption, audio and video tracks, PDF info; Copy All; Remove Metadata | Built | Automated; **not tried by hand** | View only; editing tags isn't built. Coordinates only, no map (a map would need the network) |
| Entry points | Drop on the menu bar icon | Built | By you | |
| Entry points | Convert Files… (Open panel) | Built | Not by hand | Uses the same picker as the other entry points |
| Entry points | Services: "Convert with Converter…" | Built | Headless by me, and by you | |
| Entry points | Finder Quick Action | Built | By you | Sandboxed extension that hands the files to the app |
| Entry points | Open With, or a drop on the app's icon | Built | By you | |
| Entry points | Command-line tool `converter-cli` | Built | Run by me; offline check automated | |
| App | Menu bar only, Apple silicon, macOS 13+ | Built | Release bundle checked | macOS 13 to 25 not tested (decision 4) |
| App | Job list with progress, Cancel, Show in Finder; two jobs at a time, one video at a time | Built | Automated; list seen by you | |
| App | Progress ring and done/failed badge on the icon | Built | Not verified | |
| App | Off the main thread, cancellable, no partial files, never overwrites | Built | Automated | |
| App | Quitting during a conversion cancels and cleans up | Built | Not verified | |
| App | Settings window: quality, metadata, favourite formats, video, audio, PDF | Built | Automated | Each tab rendered offscreen |
| App | Launch at login | Built | Not verified for real | Turning it on adds a real login item; tested with a stand-in |
| App | Show results in Finder | Built | Not verified | |
| App | Notifications when done | Skipped | — | Optional in the plan; the icon badge covers it |
| App | Fully offline | Built | Automated | No networking symbols in the app, extension or CLI; the extension has no network entitlement |
| Distribution | Developer ID, hardened runtime, notarization | Skipped | — | No Developer ID yet (decision 2). Ad-hoc signed; Xcode disables the hardened runtime for ad-hoc builds |
| Distribution | Optional engines (ffmpeg, libwebp, LAME, libopus) | Skipped | — | Not approved (decision 1) |
| Research | Comparison with the real app (REA) | Skipped | — | No copy of the app was provided |

## Known limitations

- An ADTS `.aac` input keeps about 0.05 s of encoder delay, because the
  format can't record it.
- Video resize presets fit the frame inside a 16:9 box. A portrait clip
  stored without rotation metadata comes out smaller than its label says.
- Placeholders: the name "Converter", the bundle ID `com.example.Converter`,
  and no app icon.
- Debug builds contain the `DebugAutoPickConverter` test hook; Release
  builds don't.
- Builds go to `~/Library/Caches/Converter`, because iCloud syncs
  `~/Documents` and breaks code signing.

## What's left before shipping

1. Choose a name, a bundle ID and an icon.
2. Join the Apple Developer Program, then sign with Developer ID, turn on
   the hardened runtime, notarize, and ship a DMG.
3. Put the project in git.
4. Optionally: test on macOS 13 to 15, and decide on the optional engines.
