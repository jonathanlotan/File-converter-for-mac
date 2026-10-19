# Converter: design for macOS 26 and 27

Date: 2026-10-19. Built with Xcode 27.1 and the macOS 27.0 SDK. Tested on
macOS 26.6.2, so anything that only exists on macOS 27 still needs
checking after the update (see [Checks after updating to macOS 27](#checks-after-updating-to-macos-27)).

## Sources

- **The macOS 27 SDK on this Mac.** Availability comes from the
  framework headers and Swift interfaces, so these facts are exact.
- **Xcode 27.1's Icon Composer template,** and a real `.icon` package
  installed on this Mac, for the icon format.
- **Apple's Human Interface Guidelines and WWDC material,** gathered by a
  research pass (summarised under [Guidance applied](#guidance-applied)).

## What the SDK says changed

| Area | API | Available | What it means here |
|---|---|---|---|
| Liquid Glass (SwiftUI) | `glassEffect(_:in:)`, `Glass` (`.regular`, `.clear`, `.tint`, `.interactive`), `GlassEffectContainer`, `glassEffectID`, `glassEffectUnion`, `glassEffectTransition` | macOS 26 | Used for the wheel |
| Shapes | `ConcentricRectangle` | macOS 26 | — (the wheel draws its own concentric pills) |
| Liquid Glass (AppKit) | `NSGlassEffectView` (`cornerRadius`, `tintColor`, `style`), `NSGlassEffectContainerView` | macOS 26 | Not needed: the glass is drawn in SwiftUI |
| Liquid Glass (AppKit) | `NSGlassEffectView.effectIsInteractive` | **macOS 27** | — |
| Corners (AppKit) | `NSView.cornerConfiguration`, `NSViewCornerRadius.containerConcentric`, `NSViewCornerConfiguration` | **macOS 27** | AppKit's version of concentric corners; nothing here is AppKit-drawn |
| Menus | `NSMenuItem.sectionHeader(title:)` | macOS 14 | Used for "Tools", "Actions", "Conversions" |
| Menus | `NSMenuItem.preferredImageVisibility` (`.automatic` / `.visible` / `.hidden`) | **macOS 27** | The header says AppKit "will typically hide images" in menus from macOS 27; the app leaves this on `.automatic` |
| Menu bar | `NSStatusItem.expandedInterfaceDelegate`, `NSStatusItemExpandedInterfaceSession` | **macOS 27** | For status items that open their own window instead of a menu; Converter uses a menu, so it doesn't apply |
| Lists (SwiftUI) | `reorderable()`, `reorderContainer(for:…)`, `swipeActions` on macOS | **macOS 27** | Candidate for reordering the shelf later |
| Pickers (SwiftUI) | `.tabs` picker style | **macOS 27** | — |
| Icons | Icon Composer `.icon` (layered, Liquid Glass) | Xcode 26+ | Used for the app icon; Xcode also builds `AppIcon.icns` for macOS 13–25 |

## Guidance applied

From Apple's Human Interface Guidelines (materials, menus, the menu bar,
settings, app icons), the macOS 27 release notes, "Adopting Liquid Glass",
and WWDC25 sessions 219/310/356 and WWDC26 sessions 102/269/272/289.

| Guidance | How Converter follows it |
|---|---|
| Liquid Glass belongs to the functional layer (controls floating over content), not to content | Only the wheel uses glass. Shelf rows, settings forms and menus don't |
| Use it sparingly; titles and status displays don't get glass | One glass disc for the whole wheel. The centre caption is a fill drawn on it, not its own glass |
| Avoid glass on glass; group nearby glass in a container | The disc and the sub-ring are the only glass shapes, side by side in one `GlassEffectContainer`; nothing glass sits on top of glass |
| Regular glass for text-heavy surfaces; clear only over media | `.regular` everywhere |
| Tint only for primary actions or status, and not several controls | Only the slice under the pointer is filled with the accent colour |
| Interactive ("bounce") glass only on controls — "a little goes a long way" (WWDC26-289) | Only the main disc is `.interactive()` |
| Concentric shapes | Selection pills are inset 4 pt with corners that follow the ring; shelf highlights are rounded inside the window's corners |
| Custom elements must be tested with Reduce Transparency, Increase Contrast and Reduce Motion | The fallback material and the glass follow Reduce Transparency; Increase Contrast adds outlines and darker dividers; Reduce Motion turns the spring and morph into fades |
| Menu item icons: sparingly, and every item in a group or none (HIG, updated 2026-06-08) | Only the Actions section (all six) and the Settings/About and Quit groups have icons, and only on macOS 26. Formats and tools don't |
| macOS 27 hides symbol images in menus by default (Settings, Share and Print keep theirs) | `preferredImageVisibility` stays `.automatic`, so the system decides |
| Menu bar extras: template image, "display a menu — not a popover" | A template symbol with an `NSMenu`. The macOS 27 expanded-interface API only applies to items that open their own window, so it isn't needed |
| Let people hide the menu bar extra, and don't rely on it being visible | New "Show icon in menu bar" setting. Opening the app again (Finder, Spotlight) shows Settings |
| Settings: toolbar of panes, window titled after the pane, minimise and zoom dimmed, sized to the pane, reopens the last pane, ⌘, | All done with `NSTabViewController` (`.toolbar` tabs), `toolbarStyle = .preference`, a titled and closable window, preferred-size panes and a remembered pane |
| App icons: Icon Composer `.icon`, at most four groups, SVG layers, the system adds blur, shadow and highlights; Xcode builds a similar icon for older macOS | Three groups of SVG layers with system shadow and translucency; the build contains `Assets.car` and `AppIcon.icns` |
| macOS 27 ignores the old-design opt-out (`UIDesignRequiresCompatibility`) | Not used: the app adopts the current design |

Points the research couldn't confirm, to check by hand: how menu icons
behave in status item and pop-up menus on macOS 27, and whether
`NSActionTemplate` looks right as the Quick Action's preview-pane icon
(forum reports suggest a small bitmap looks better).

## What changed in the app

### The wheel
- **macOS 26 and later:** the wheel is one regular, interactive Liquid
  Glass disc. When a group opens, its sub-ring is a second glass shape in
  the same `GlassEffectContainer`, with a matched-geometry transition, so
  it grows out of the disc.
- **macOS 13–25:** the same two shapes use `NSVisualEffectView` with the
  popover material, blurred from behind the window and cut to shape with a
  mask image, plus a soft shadow.
- **Selection:** a rounded pill inset 4 pt from its slice, with corners
  that follow the ring (concentric), in the user's accent colour. A
  group's slice uses a light tint of the accent colour while its sub-ring
  is open.
- **Centre:** a quiet inset area 6 pt inside the ring, a fill rather than
  glass, darker when a drop there would cancel. It shows the ring's name
  with its key ("⇧ CONVERT"), what a drop would do, and three dots for the
  three rings, in scrolling order: Actions, Tools, Convert.
- **Motion:** the wheel springs in, and switching rings cross-fades the
  labels. With Reduce Motion, it only fades.
- **Accessibility:** glass and the material both follow Reduce
  Transparency. With Increase Contrast, the ring and disc get outlines and
  the dividers get darker.

### Menus and the menu bar icon
- The headers "Convert “file”", "Tools", "Actions" and "Conversions" use
  the system's section headers on macOS 14 and later, and greyed-out
  items on 13.
- Icons only where a whole group has them (Actions; Settings and About;
  Quit), and only from macOS 26. On macOS 27, AppKit decides when they
  show.
- Job rows show the file's icon.
- The menu bar icon remembers its position, can be hidden in Settings, and
  opening the app again shows Settings.

### Settings
- The window is now a standard Mac settings window: toolbar tabs with
  icons (General, Formats, Images, Video & Audio, Documents),
  `toolbarStyle = .preference`, and the title follows the tab. Each pane
  is a grouped SwiftUI form sized to fit. It reopens on the last tab and in
  the same place. On macOS 26+ the toolbar is Liquid Glass.

### Shelf (Float)
- Rows show a 32 pt icon, the name, the kind and size, and a rounded hover
  highlight inside the window's corners. The remove button appears on
  hover. There's an empty state with a tray symbol.

### Share, crop and metadata (added after the redesign)
- **Share:** the menus use the system's own **Share…** item
  (`NSSharingServicePicker.standardShareMenuItem`), which keeps its icon
  on macOS 27 and lists every service. In the wheel, Share is a sub-ring
  of shortcuts with the system share picker under More…. The picker
  points at a small invisible window at the pointer, because the wheel
  has already closed by then.
- **Crop editor:** a standard titled, resizable window. The image sits on
  a dark backdrop so the crop reads clearly, the way photo editors do. The
  area outside the crop is dimmed, with a rule-of-thirds grid and
  white L-shaped corner and edge handles. The controls are standard
  AppKit-style SwiftUI controls in a bottom bar: an Aspect pop-up, width
  and height fields, Reset, Skip (for several images), Cancel (Esc) and
  Crop (Return, the default button). On macOS 15 and later the pointer
  becomes the system's resize and grab pointers over the handles. There's
  no glass in the window: it's content.
- **Metadata window:** a grouped form like Settings, with the file's
  thumbnail and name at the top and the window subtitle "Metadata". Values
  can be selected and copied, with Copy All for everything. Previous and
  Next buttons step through a selection.

### App icon
- `Converter/App/AppIcon.icon`, original artwork that doesn't borrow from any other app: an indigo
  background (darker in dark mode), a translucent back file, a front file
  with text lines, and a curved arrow from one to the other. Each of the
  three groups gets the system's glass treatment.
- xcodegen types `.icon` files as `wrapper.icon`, which the asset compiler
  ignores, so `project.yml` re-types it as `folder.iconcomposer.icon` after
  each generation.

## Checks after updating to macOS 27

1. **Menu icons:** open the menu bar menu and a format menu (including
   from Services or the Quick Action). Icons should follow the system,
   usually hidden; Settings may keep its icon. If the Actions section reads
   badly without icons, decide whether to force
   `preferredImageVisibility = .visible` there.
2. **The wheel's glass:** open the debug build's menu > **Preview Wheel
   (Debug)**, and Shift-drag a real file. Check how legible it is over
   light and dark windows, and how the sub-ring morphs.
3. **The settings toolbar:** check the tab icons and window resizing.
4. **The app icon:** check it in Finder, the About panel and Login Items,
   in both light and dark mode.
5. **Accessibility:** turn on Reduce Transparency, Increase Contrast and
   Reduce Motion, then open the wheel.
6. **Glass refinements:** macOS 27 changes Liquid Glass without a rebuild
   (diffusion, edges, highlights), and adds a user slider from clear to
   tinted. Check the wheel at both ends of that slider.
7. **Share, crop and metadata:** check the Share… item's icon in the menus,
   that the share picker from the wheel's Share › More… appears at the
   pointer, and the crop editor's pointers over the handles.
8. **Optional macOS 27 extras:** reordering on the shelf
   (`reorderable()`), and interactive AppKit glass if any AppKit glass is
   added later.
