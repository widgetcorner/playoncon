# iPhone Duo layout validation

Validated October 6, 2026. This is a tested Flutter layout adaptation, with the
release and accessibility gaps below still open.

## Implementation

- Navigation follows the hosting iOS view's `verticalBarEdge` trait. A small
  event channel forwards physical left/right/none and active reserved regions.
  The native observer updates with layout, safe-area and relevant trait changes.
  `none` is distinct from API unavailability. Android and older iOS retain bottom
  navigation; no device names, orientation guesses or width thresholds select
  Apple's bar edge.
- A stable, keyed content slot retains the mounted destinations when bars move.
  The boundary is above the Navigator, so open details, dialogs and input retain
  state during display changes. Camera clearance is combined with existing safe
  insets using the maximum, not added twice. Stale native geometry is ignored.
- Side navigation occupies the system's outer strip, beneath its status controls,
  rather than adding another rail inside the horizontal safe-area inset. Content
  receives the freed width. Buttons avoid active camera/status regions using
  scene-local coordinates. Side controls also avoid any crease crossing the
  strip. The same placement applies to physical left and right edges and RTL
  interfaces.
- Folded displays retain the full app viewport: the schedule and map use both
  halves, and folding does not constrain the Navigator to one pane. Active
  folds remain available in MediaQuery so dialogs and sheets avoid the crease
  locally. Floating map cards and controls avoid it independently of map artwork.
- Schedule content is limited to 760 logical pixels; detail, Info and Contact
  reading content to 720. Narrow/large-text notices and reminder options wrap;
  empty states and the custom reminder sheet scroll. The picker keeps its value
  and controller mounted through resizing.
- Map resizing preserves normalized focal position, zoom and selected venue.
  Pins and labels are clipped to the viewport so they cannot paint over the
  navigation rail. Labels account for text scaling and direction; venue cards
  wrap and scroll, with controls remaining reachable. Map focus moves respect
  reduced motion and map pins expose named, selected semantics.

Apple Liquid Glass principles are applied through separated navigation/content,
grouped controls, safe regions and adaptive appearance. Controls remain Flutter
Material/Cupertino rendering with the existing Play On Con theme. This does not
claim native Liquid Glass materials, native toolbar overflow or native sheet
placement, and adds no effects dependency.

## Build environment and compatibility

| Item | Verified value |
| --- | --- |
| Xcode | 27.1, build **27A9275** |
| SDK linked by the tested app (`DTSDKName`) | **iphonesimulator27.1** |
| Xcode recorded in tested app (`DTXcodeBuild`) | **27A9275** |
| Duo runtime | iOS 27.1, **24A94232** |
| Other tested runtime | iOS 27.0, **24A434** |
| Flutter / Dart | Flutter **3.47.1**, Dart **3.13.1** |
| Repository deployment target during Duo validation | **iOS 13.0**, restored afterward |
| Actual Duo validation binary minimum (`MinimumOSVersion`) | **iOS 15.0** |
| Approved release `2026.10.6+28` project target / IPA minimum | **iOS 15.0**, approved October 6, 2026 |

During Duo validation, installed Flutter automatically raised the project minimum
to iOS 15 and updated four SDK-pinned dependency resolutions. Those tracked
project/analysis/lockfile changes were restored after that validation; it did not
approve a release minimum change.

For the October 6, 2026 tester release `2026.10.6+28`, the owner approved iOS 15
as the minimum supported version. The current project targets and verified IPA
minimum are **iOS 15.0**. This release decision is resolved; iOS 13/14 support is
no longer part of the release baseline. The new native APIs remain guarded at
runtime for iOS 27.1, and their declarations were verified against the installed
SDK. Building this native integration requires the iOS 27.1 SDK or later.

Duo validation builds used the bundled offline schedule/map, with no production
configuration or live network services. The available architecture document referenced by
AGENTS.md was missing from its recorded path; existing repository patterns were
used instead.

## Verification

Final `flutter analyze --no-pub`: no issues. Final `flutter test --no-pub`:
**50 tests passed**. Final `flutter build ios --simulator --debug --no-pub`:
successful. `git diff --check`: clean.

Focused tests cover:

- Stream changes, unsupported platforms, malformed geometry and zero-width folds.
- Physical edges in RTL, safe-area consumption, supported horizontal placement
  on wide windows, scrollable navigation at 320×220 and 3× text. Strip tests also
  check actual button centers, camera clearance and crease avoidance without
  reducing page width or height. Open dialogs and sheets stay mounted while
  moving clear of vertical and horizontal folds.
- Mounted screen, text input, selection, focus and pushed-route continuity.
- Geometry changes from 280–1100 logical pixels wide, short windows and 2.5–3×
  text. Custom reminder selection was dragged, resized and confirmed.
- Repeated map resizing and selection/zoom/focal-point continuity. A rendered
  pixel regression reproduced 7,041 pixels escaping the map viewport before
  clipping and zero afterward, while retaining drag-to-pan behavior.
- Full-size content through both fold axes, reminder picker selection and
  confirmation through folding, and crease-safe map overlays. Switching the
  rail between physical edges with unchanged map dimensions preserves the map
  transform and refreshes overlay coordinates.

The content suite also passed with a future convention date to exercise the
countdown: `flutter test --no-pub test/content_layout_test.dart
--dart-define=POC_EVENT_THURSDAY=2027-07-08`.

### Native simulator observations

Screenshots are local build artifacts under `build/duo-validation/` (ignored by
Git). These are simulator frames, not mocked dimensions. The table lists the
specific verified files; earlier diagnostic frames in that directory are not
final evidence.

The strip correction was visually checked in full-screen inner landscape:
`inner-landscape-info-shared-strip.png` shows navigation in the far-right status
strip. The subsequent fold correction was checked in native Partially Open pose
in both orientations: the schedule/map use the entire scene, the selected
Theater card stays clear of the crease, and the open reminder picker retains
its displayed 15-minute value when rotated. The fold screenshots below replace
the earlier single-pane `partial-fold-final.png`, which is obsolete.

Native Split View must still be repeated: reinstalling reopened the app
full-screen, and the automated home-bar drag did not reliably restore the
user's right-side Split View. Other orientation screenshots below predate the
strip/fold follow-ups unless specified.

| Case | Observed result / evidence |
| --- | --- |
| Outer portrait, 1398×2034 px | Right rail, camera/status clearance, selected Theater card and all destinations reachable. `outer-map-final.png` |
| Outer rotated, 2034×1398 px | Side placement and selected venue retained; controls clear of the corner camera. `outer-rotated-map-final.png` |
| Inner portrait, 2007×2853 px | Bottom navigation; My Schedule and saved Open Gaming event visible. `inner-portrait-saved.png` |
| Inner landscape, 2853×2007 px | Right rail; selected map venue survives rotation. Final dark map is clipped beside the rail. `inner-landscape-map-dark-final.png` |
| Open event across outer → inner | Open Gaming detail retained; title, description, Back and Save remain accessible beside system controls. `inner-landscape-detail.png` |
| Open custom reminder, landscape → portrait | Picker stayed open at its selected value; returned to reminder dialog and saved event with No reminder. Reproduce using the flow below. |
| Partial fold, inner landscape, 2853×2007 px | Schedule uses both halves, with navigation in the right strip. `partial-fold-landscape-full-schedule.png` |
| Partial fold, map in both axes | Map spans both halves; selected Theater card remains clear of the crease and survives rotation. `partial-fold-landscape-full-map.png`, `partial-fold-portrait-full-map.png` |
| Regular iPhone 18 Pro, iOS 27.0 | Bottom navigation and Info layout displayed correctly. `iphone-ios27-fallback.png` |
| iPad Pro 11-inch (M5), iOS 27.0 | Readable centered Info content and bottom navigation. `ipad-ios27-fallback.png` |

### Reproduce the native pass

1. Build the simulator app using the command above. Review Flutter's automatic
   toolchain migrations separately from app code, especially the deployment
   target. Install `build/ios/iphonesimulator/Runner.app` on iPhone Duo in Device
   Hub and launch `com.fuller.playoncon`.
2. In Schedule, open an event, use **Open** on the simulator, rotate, then return.
   Save Open Gaming with **No reminder**, select **My Schedule**, and rotate
   between the two inner orientations. The saved event and selected tab persist.
3. On an unsaved event, choose **Custom…**, change the minute wheel and rotate
   while the picker is open. Confirm or dismiss; verify the chosen value survives.
4. Open Map, select Theater, pan, then change between **Closed**, **Open** and
   **Partially Open**, rotating in each pose. Check focal position, selection,
   card scrolling, camera clearance and no labels painting into navigation.
   In Partially Open pose, confirm map artwork and schedule occupy both halves,
   while venue cards and open reminders stay to one side of the crease.
5. Repeat in light/dark and with accessibility text settings. For screenshots,
   run `xcrun simctl io <device-id> enumerate` and select the active display via
   `screenshot --display=<display-id> <path>`. The default display can be the
   inactive inner screen while the device is closed, producing a blank image.

## Remaining validation before release

- Native Split View on both sides, continuous Device Hub window resizing, and
  native RTL switching. Widget tests cover both physical edges and resizing but
  do not replace these native checks.
- Full VoiceOver navigation, hardware keyboard, largest native Dynamic Type,
  increased contrast, reduced transparency and native reduced-motion runs.
  Semantics, input/focus continuity, large text and reduced-motion code paths
  have narrower coverage as described above.
- Android device/emulator smoke test, real Duo hardware, release-mode build and
  production schedule/configuration. Shared-code tests and Android channel
  fallback pass; no Android binary/device was validated in this task.
- Older supported runtime validation. The iOS 15 minimum was approved for release
  `2026.10.6+28`; iOS 27.0 verifies the pre-27.1 fallback, while iOS 15–26 runtimes
  were not run during Duo validation.
- Non-full-span reserved fold shapes are not handled as a split by Flutter's
  `DisplayFeatureSubScreen`; any such platform geometry needs a separate test.
- App Store screenshots/previews and submission are outside this layout task.

## References

- [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
- [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)
- [UITraitCollection.verticalBarEdge](https://developer.apple.com/documentation/uikit/uitraitcollection/verticalbaredge)
- [UIView reserved regions](https://developer.apple.com/documentation/uikit/uiview/reservedregions(kind:))
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Design for iPhone Duo — fold avoidance](https://developer.apple.com/videos/play/tech-talks/111466/?time=568)
