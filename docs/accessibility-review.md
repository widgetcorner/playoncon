# Play On Con accessibility review

Reviewed October 6, 2026 against Apple's App Store accessibility criteria and
WCAG 2.1 AA. Seven labels are relevant to this app. Practical gaps have been
fixed, with device signoff still needed before declaring complete support.
Captions and Audio Descriptions should remain unclaimed because Play On Con
does not play audio or video.

Apple requires **all common tasks** to work with a claimed feature, evaluated
separately for iPhone and iPad. Automated tests establish implementation
behavior; VoiceOver and Voice Control also need proficient hands-on testing.
[Apple support criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels)

## Feature decisions

| Feature | Implementation after this review | Before claiming support |
| --- | --- | --- |
| [VoiceOver](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/voiceover-evaluation-criteria) | Named controls, saved state, full attribute meanings, headings, labeled reminder input, map descriptions and a Places list with venue and live cart information. | Complete the task matrix below using VoiceOver alone on iPhone and iPad. Check focus, rotor navigation, scrolling, permissions and notifications. |
| [Voice Control](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/voice-control-evaluation-criteria) | Session-specific Save/Remove names, named map controls, standard Places rows, typed reminder minutes, explicit cancellation and button roles. | Complete the matrix using voice alone. Verify Show names, Show numbers, scrolling and dictation without touch assistance. |
| [Larger Text](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/larger-text-evaluation-criteria) | Primary text scales beyond 200%; content wraps and scrolls. Schedule tabs grow and scroll at large sizes. Places provides scalable alternatives to bitmap labels. | Finish the largest-text device walkthrough, including landscape, reminders with the keyboard, and Places. Predictable navigation controls may stay smaller under Apple's criteria. |
| [Dark Interface](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/dark-interface-evaluation-criteria) | System appearance drives all Flutter screens and dark map artwork. Reminder picker colors are explicit. iOS launch and host-view backgrounds now follow system appearance; Android's base launch drawable follows its theme. | Inspect cold launch, all dialogs, loading/error states and appearance changes on supported devices. |
| [Differentiate Without Color Alone](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/differentiate-without-color-alone-evaluation-criteria) | Category glyphs and labels, filled/outline bookmarks, tab underlines, venue selection size/border, cart glyphs/names and written Now/Next status provide additional cues. | Walk through the matrix in grayscale, especially selected map pins, saved sessions and live cart/location markers. |
| [Sufficient Contrast](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/sufficient-contrast-evaluation-criteria) | Theme regression tests enforce 4.5:1 for audited text roles and 3:1 for audited control roles in both themes. Map labels now have opaque surfaces. | Finish visual checks of artwork, every state and OS Increase Contrast/Bold Text/Reduce Transparency combinations. Theme ratios do not measure every pixel of the map image. |
| [Reduced Motion](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/reduced-motion-evaluation-criteria) | Both Apple's Reduce Motion and Android's Remove animations preference reach app widgets. Page transitions, reminder presentation and tab content transitions become stationary; map focus jumps, location pulse stops and loading uses a static symbol. Settings changes apply while open. | Verify system preference changes on-device, including map focus, location pulse, loading, reminders and back navigation. Direct user-controlled scrolling remains available. |
| [Captions](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/captions-evaluation-criteria) | Not applicable to current content. | Leave unclaimed. Reevaluate if in-app audio or video is added. |
| [Audio Descriptions](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/audio-descriptions-evaluation-criteria) | Not applicable to current content. Map screen-reader descriptions serve VoiceOver. | Leave unclaimed. Reevaluate if in-app video is added. |

## Findings and fixes

All eleven finding groups below were addressed. None was classified as critical;
nine were major and two were minor. The remaining work is the device validation
matrix, including external resources opened from Info.

| Finding | Severity | WCAG area | Result |
| --- | --- | --- | --- |
| Dense badges spoke emoji/codes; repeated bookmark names lacked session context. | Major | 1.1.1, 4.1.2 | Full attribute meanings, unique session names and explicit saved state. |
| Spatial map exploration lacked a text route to all places and live positions. | Major | 1.1.1, 1.3.1 | Places lists venues, category descriptions, approximate drawing positions, device location and live carts. Meaningful artwork has a description. |
| Custom venue pins lacked keyboard focus and activation. | Major | 2.1.1, 2.4.7 | Standard focusable buttons with a visible focus ring, Enter activation and native accessible focus/enabled state. |
| Custom reminders depended on a wheel; dialog choices lacked button roles. | Major | 2.1.1, 3.3.2, 4.1.2 | Labeled 1–120 minute text entry alongside the wheel, range validation, button roles and explicit Cancel. Both actions remain reachable above the keyboard at 200% text. |
| Cupertino picker colors could diverge from the app's dark theme. | Major | 1.4.3 | Explicit theme foreground and background. |
| Unselected tabs, the schedule BETA badge and selected map labels had low contrast. | Major | 1.4.3 | Stronger tab colors, contrasting badge foreground and opaque map label surfaces. Secondary/tertiary theme colors and light outlines also meet tested minimums. |
| Map motion checks ignored Apple's separate Reduce Motion flag. | Major | Motion support | A settings observer combines iOS Reduce Motion and Android Remove animations for app widgets. |
| Page/sheet/tab transitions and loading spinners retained motion. | Major | Motion support | Explicit stationary transitions and static, named loading feedback. |
| Largest system text clipped schedule tab labels; dark launch flashed white. | Major | 1.4.4, dark appearance | Tabs grow and scroll; native launch and initial view backgrounds follow system appearance. |
| Countdown speech split numbers from abbreviated units. | Minor | 1.3.1 | One description in days, hours and minutes, without an every-second live announcement. |
| Date/detail structure and sync failures lacked explicit semantic cues. | Minor | 1.3.1, 4.1.3 | Headings, contextual metadata labels and live-region sync errors. |

Map position descriptions refer to the stylized drawing. They provide approximate
landmark context, not walking directions or surveyed accessible routes. No
location permission is requested merely by opening Places.

## Measured contrast

Rounded ratios include alpha compositing over the actual background.

| Element | Before | After | Minimum |
| --- | --- | --- | --- |
| Light unselected schedule tab | 3.35:1 | 5.02:1 | 4.5:1 |
| Dark unselected schedule tab | 3.95:1 | 6.52:1 | 4.5:1 |
| Light schedule BETA badge | 1.43:1 | 5.00:1 | 4.5:1 |
| Light selected map label for Parties | 4.14:1 | 14.03:1 | 4.5:1 |
| Dark selected map labels for Gaming/Parties/Outdoors | 3.16–3.55:1 | 11.13:1 | 4.5:1 |

## Verification

- Complete Flutter suite: **79 tests passed**, including 18 new accessibility
  regression tests.
- Static analysis: **no issues**. iOS simulator debug build: **successful**.
- Future-date countdown configuration: **16 focused tests passed**.
- Large-text coverage includes 200% Places and keyboard flows, 250% schedule,
  detail, Info, Contact and reminder resizing, 300% map details, and 350%
  schedule tabs at narrow widths.
- Tests exercise save/remove state, reminder input/range validation/cancellation,
  semantic button roles/actions, map keyboard activation, live cart updates,
  location opt-in, contrast, and settings changes for motion and tab transitions.
- Native iPhone accessibility inspection exposes complete session labels,
  attribute meanings, reminder field names, values and wheel units. Numeric key
  input changed the field and displayed reminder to 25 minutes. This inspection
  does not replace VoiceOver speech/gesture or Voice Control recognition tests.
- Native dark/maximum-text and light/standard-text previews on iPhone 18 Pro and iPad Pro 13-inch
  showed readable, scrolling content. The iPhone schedule tab now shows its full
  label, with horizontal scrolling to the next tab. Captures are under
  `build/accessibility-review/`; each simulator's original light/standard text
  settings were restored. These previews cover schedule and Info, not the full
  signoff matrix.

Flutter 3.47.1 treats the iOS motion preference separately from
`MediaQuery.disableAnimations`; the new app boundary deliberately connects
them. Framework transitions are also configured explicitly because a
MediaQuery override alone does not change their animation controllers.
[Flutter animation preference documentation](https://api.flutter.dev/flutter/widgets/MediaQueryData/disableAnimations.html)

## Device signoff matrix

Run each task on iPhone and iPad. For each device, record VoiceOver, Voice Control,
largest text, dark appearance, grayscale, contrast settings and Reduce Motion.
Include the minimum supported iOS version when validating the release.

| Common task | Expected result |
| --- | --- |
| First launch offline and change tabs | No mandatory permission prompt; cached schedule and map remain usable; destination names and selected state are clear. |
| Browse All Sessions and My Schedule | Navigate days, times, venues and full attribute meanings; scroll long lists; switch tabs at large text. |
| Open an event and return | Read full title, details, metadata and sub-schedule; back navigation returns to useful context. |
| Save and remove a session | Identify the specific session's control; choose No reminder, At start or Custom; perceive saved/removed state. |
| Enter, validate and cancel a custom reminder | Dictate or type minutes, adjust the wheel, recover from invalid values, and reach confirmation/cancellation with keyboard and large text. |
| Grant or deny reminder permission | App remains usable; future reminders are scheduled and announced correctly. Verify native notification presentation. |
| Use Show on map and Places | Reach every place through names; read venue details; return and close the selection. Keyboard users can activate pins. |
| Enable or deny location | Clear permission/disabled/off-map feedback; approximate nearest-place information is available without color or spatial gestures. |
| Inspect live carts | Identify cart and driver, read approximate position, observe updates and stale removal. Use a configured test environment. |
| Refresh online and offline | Reach the named Refresh control; loading and sync failures remain understandable; updates preserve usable focus. |
| Use Info and Contact | Read all information; open public program/schedule, maps, Discord and contact composer; return safely. Check linked documents separately for accessibility. |

Declare each relevant label after its column passes every common task. Keep
Captions and Audio Descriptions unchecked while the app has no qualifying media.
