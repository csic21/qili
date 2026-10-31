# Qili native design refresh

## Direction

An original, calm Mac utility: neutral charcoal surfaces, restrained green for
selection/action, readable metadata, and a clear sequence from measurement to review.
Qili's name, mascot, app icon, bundle identifier, and underlying tool capabilities stay
unchanged. The five pages share the same shell, controls, spacing and contrast palette.
Users can switch between light, dark, and follow-system appearances from the sidebar;
both palettes keep the same hierarchy and are checked for contrast.

Reference principles, not copied screens:

- [Things 3, Cultured Code](https://culturedcode.com/things/features/): clear hierarchy,
  grouped work and progressive detail.
- [Transmit 5, Panic](https://help.panic.com/transmit/transmit5/getting-started/): aligned
  file data and inspection close to the item being reviewed.
- [DaisyDisk's Collector](https://daisydiskapp.com/guide/4/en/DeletingFiles/): separate
  discovery, selection and action. Qili retains its own explicit cleanup modes: Trash by
  default, direct delete behind a second confirmation.
- [Apple sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars):
  concise navigation, familiar symbols and keyboard access.

## What changed

### Space cleanup

- Starts with an explicit “开始扫描” action instead of scanning on first appearance.
- Shows category progress and measured bytes while scanning. Category counts are not
  presented as a time estimate, and incomplete results remain visibly incomplete.
- Separates discovered size, selected size and cleaned size. No item is preselected.
- Expands each review item to its selectable full path and a Finder reveal action.
- Keeps selected count, size and the final confirmation outside the scroll area.
- Offers two committed cleanup modes: move to Trash (recoverable) and direct delete
  (frees space immediately, unrecoverable). Direct delete requires a second alert with
  an acknowledgement toggle; the destructive button stays disabled until it is checked.
- Reports real per-item counters while cleaning (completed/total and the current name),
  with no invented time estimate, and keeps the outcome wording mode-aware.
- Distinguishes complete, partial, failed and unchanged outcomes in words and symbols.
  Failures are visible without opening a disclosure.
- States clearly that files in Trash still consume disk space, and that direct deletion
  cannot be recovered from Trash.

### Shared components and the other pages

- Metadata palette passes 4.5:1 for opaque card, hover and selection surfaces in
  both the light and the dark appearance (scripts/check_design_contrast.py).
- Selection has a separate fill and outline; hover does not impersonate selection.
- Check controls have 28-point targets and an explicit keyboard focus ring. Main
  actions have 34-point targets. Native segmented controls select app subpages.
- File-map view and hidden-file preferences persist. Navigation resets scroll position
  without replacing page identity. The default is an aligned list; equal-size cards
  explicitly explain their layout and show numeric shares.
- Every distribution strip segment has a keyed size/share legend, including “other.”
  Filtering does not silently change the denominator.
- CPU/GPU history uses a fixed 0–100% range. Network rates retain labeled auto-scaling.
  Hardware context and missing metrics have clear text states.
- System startup controls are disabled as well as labeled read-only.

## Safety boundaries

The scan implementation, allowlisted roots, exclusions, physical file traversal,
cleanup path/symlink revalidation, command execution and update/security mechanisms are
unchanged. DEBUG-only fixture constructors bypass live initialization and guard scan/stop/cleanup,
application/network/startup/maintenance actions and hardware polling at store entry points.
Finder and folder-panel actions are inert, with isolated view preferences for fixtures.
Both cleanup modes revalidate the same paths and process only checked children.

There is no empty-Trash action — the app moves items to Trash but never empties it — and no
file-map deletion, speculative metric, or new network service.
App inventory now offers a separate uninstall review sheet with a fixed selection bar,
a second confirmation, graceful app termination, per-item outcomes and a recheck of known paths.
Only exact user-library paths and verified in-app user LaunchAgents can be moved; system agents
are read-only. Data directories require explicit selection and acknowledgement. Identity and
symlink checks run again before moving; failure to move the app preserves its data. Shared
bundle-ID paths stay read-only when another installed copy exists. Uninstall snapshots use
inert `/QiliPreview` fixtures, and filesystem tests use an injected simulated Trash. Maintenance retains the existing selections and authorization.
The test renderer never constructs the live ContentView or launches the app entry point.

## Verification

Portable checks:

```sh
python3 scripts/check_design_contrast.py
bash -n scripts/capture_design_snapshots.sh
git diff --check
```

Native checks, on macOS 14+ with Swift/Xcode selected:

```sh
swift test
swift build --configuration release
bash scripts/capture_design_snapshots.sh
```

Capture uses real production SwiftUI views inside NSHostingView/NSWindow and AppKit
bitmap capture, including native window controls. It does not use HTML mockups or
[ImageRenderer](https://developer.apple.com/documentation/swiftui/imagerenderer), which
can omit AppKit-backed controls. All data is synthetic, rooted under `/QiliPreview`,
and actions cannot perform live filesystem work. An explicit opt-in and output path
are required. Captures use fixed 1060×680 and 1220×820 window sizes, a Chinese locale,
dark Aqua (the release default appearance), and two scrolled process-table views. Native
progress indicators are paused
for captures; these are review images, not a claim of pixel consistency across OS releases.

Native compilation, existing safety regressions, fixture/outcome tests and PNG export
must pass on macOS before acceptance. Portable source checks cannot establish a native
build or visual result.

The 46-image capture matrix covers cleanup initial, scanning, results, selection, empty,
inaccessible, moving, deleting, complete, partial and failed states; file-map list/cards/empty/error;
status readings/unavailable metrics and the scrolled process table; app inventory/updates/
startup items; and maintenance selection/results. Both window sizes use isolated synthetic
fixtures. Native increased-contrast routing is not verified by these captures. Interactive keyboard,
VoiceOver and interruption flows still need manual review;
static images do not establish those behaviors.

Manual acceptance checklist:

- Inspect all exported PNGs at both sizes, especially lowest visible text and the fixed
  selection bar. Check 1× text, long names, full paths, empty and incomplete results.
- Navigate with Command-1 through Command-5, Tab/Shift-Tab and Space. Check focus rings,
  screen-reader names, mixed category selection and disabled system startup controls.
- Stop and restart scanning; repeatedly change pages; confirm cancelled dialogs do
  nothing. Check that every cleanup path still requires explicit confirmation, and that
  direct deletion stays disabled until the recovery toggle is checked.
- Navigate folders in list and card modes, change hidden-file preferences, go back and
  rescan. Verify the preference survives navigation and filtering preserves the denominator.
- Review Apps, maintenance, file map and status at both window sizes. Check app search,
  update/startup subpages, native controls and unavailable hardware readings.
- Verify live operations only on disposable, explicitly authorized test fixtures. Do
  not use real cleanup, uninstall, update or maintenance operations for screenshot QA.

Uninstall sheet snapshots (review and partial result) can be rendered separately:

```sh
QILI_CAPTURE_UNINSTALL=1 QILI_SNAPSHOT_DIRECTORY="$PWD/.build/uninstall-snapshots" \
  swift test --filter DesignSnapshotTests.testCaptureUninstallSnapshots
```
