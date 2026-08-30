# Offload — Human Interface Guidelines audit

*Measured against the codebase at v2.7.0 (build 48). Counts are `grep` over `Offload/**/*.swift`,
so they are floors, not estimates. No code has been changed.*

This is the inventory that precedes the HIG rework. It is ordered by how much each item hurts a
real person using the app, not by how hard it is to fix.

---

## Tier 1 — accessibility failures

These are settings Apple treats as guarantees. Offload currently ignores all three.

### 1.1 Text does not scale. At all.

| Measure | Count |
|---|---|
| `.font(.system(size:))` — hardcoded points | **87**, across 24 files |
| `dynamicTypeSize` | **0** |
| `ScaledMetric` | **0** |
| `Font.custom` without `relativeTo:` | 0 (the Manrope helper is fine) |
| Files using semantic text styles | 31 |

The custom Manrope faces are *not* the problem — `Font.Offload.manrope` is built correctly. The
problem is the 87 places that bypass it with a literal point size. A person who sets Larger Text
sees no change in most of the app, and at accessibility sizes the layouts are untested and
almost certainly break: nothing uses `ScaledMetric`, so every fixed frame, padding, and icon
well stays put while whatever text *does* scale grows into it.

**Apple's bar:** text must scale to at least 200% and stay fully visible — not truncated, not
overlapping, not unreachable.

### 1.2 Reduce Motion is not respected anywhere

| Measure | Count |
|---|---|
| `accessibilityReduceMotion` | **0** |
| `withAnimation` / `.animation(…)` | 91 |
| `appearIn(…)` staggered entrances | 51 call sites |
| `scrollTransition` entrances | 2 (`scrollAppear`, `scrollAppearSubtle`) |

Every screen animates its cards in on a stagger (`Motion.swift:94`), and cards scale and lift as
they cross the viewport (`Motion.swift:83`). For a person who has asked the system to stop moving
things — often because motion makes them ill — none of it stops.

Note this is *our* motion, so the system cannot fix it for us. System materials adapt to Reduce
Motion automatically; hand-rolled `scrollTransition` and stagger do not.

### 1.3 The light palette fails contrast

Computed against `Theme.swift`. WCAG needs 4.5:1 for normal text, 3:1 for large.

| Pair | Ratio | Normal | Large |
|---|---|---|---|
| teal on white surface | **2.90:1** | FAIL | FAIL |
| amber on white surface | **2.18:1** | FAIL | FAIL |
| green on white surface | **2.28:1** | FAIL | FAIL |
| red on white surface | 3.76:1 | FAIL | pass |
| muted on cream background | 4.25:1 | FAIL | pass |
| text on cream background | 16.58:1 | pass | pass |
| indigo on white | 9.90:1 | pass | pass |
| *dark mode, all pairs* | 5.86 – 15.96:1 | pass | pass |

**Dark mode is fine. Light mode is where the app fails.** And these are not decorative colours —
teal is the label colour on the habits card, amber is the nudge text, green is completion, red is
overdue. The semantic colours carrying meaning are the ones that fail.

### 1.4 Accessibility labels are sparse

38 `accessibilityLabel` calls against an app with hundreds of interactive elements. Icon-only
buttons without labels are unusable under VoiceOver. No audit of traits, values, or reading order
has ever been done.

---

## Tier 2 — hand-built replacements for system behaviour

Each of these opts the app out of behaviour iOS gives away, including the accessibility and
Liquid Glass adaptation that comes with it.

| Ours | File | Native equivalent | Verdict |
|---|---|---|---|
| `SwipeToDeleteModifier` | `SwipeToDelete.swift:43` | `.swipeActions` | Replace. The app already uses `.swipeActions` in 3 places, so it maintains two swipe systems. |
| `TaskSwipeActions` | `TaskSwipeActions.swift:13` | `.swipeActions` | Replace, same reason. |
| `ReorderableRow` | `ReorderableRow.swift` | `.onMove` in a `List` | Investigate. `.onMove` exists in 2 places already. |
| `PressableButtonStyle` | `Motion.swift:112` | `.buttonStyle(.glass)` / `.glassProminent` | Replace on iOS 26 — the system style is the one that gets Liquid Glass and its accessibility adaptation. |
| `offloadCard()` | `Motion.swift:71`, 25 call sites | `List`/`Section` grouped style, or plain surfaces | Decide per surface. See §4. |
| `FlowLayout` | `FlowLayout.swift`, 8 refs | No native equivalent | **Keep.** Legitimately missing from SwiftUI. |
| Long-press drag on the time grid | `DayTimeGrid.swift:367` | `.draggable` / `.dropDestination` | **Keep** — see §5. |

Also: **82** raw `.background(Color.Offload…)` calls against **5** uses of a system material and
**0** uses of `glassEffect`. The app paints its own surfaces almost everywhere.

---

## Tier 3 — iOS 26 platform behaviour not adopted

| API | Uses | Note |
|---|---|---|
| `glassEffect` / `GlassEffectContainer` | 0 | Not necessarily wrong — see §4. |
| `contentMargins` | 0 | Scroll content is inset with padding instead, which is the fragile way. |
| `scrollEdgeEffectStyle` | 0 | The iOS 26 edge treatment under floating bars. |
| `tabBarMinimizeBehavior` | 0 | Tab bar does not minimise on scroll. |
| `safeAreaInset` | 6 | Used; fine. |
| `scrollDisabled` | 2 | One is the drag lock on the Day grid — correct, but worth re-checking on iOS 26. |
| `.tabViewStyle(.page)` | 3 | `OnboardingView:37`, `WeekStrip:60`, `DayView:167`. Paging a `TabView` for day navigation is a UIKit-era idiom; needs a look against current paging APIs. |

Recompiling against the iOS 26 SDK gives Liquid Glass to navigation bars, toolbars, tab bars,
sheets, and `.searchable` **for free**. Offload uses a native `TabView` and native toolbars, so
some of this has probably already landed and nobody has looked at it on device.

---

## Tier 4 — hit targets

**26** frames smaller than 44×44pt. Not all are interactive — some are dots and swatches — but
these are, and are tappable:

- `CaptureView.swift:165` — 26×26
- `OnboardingView.swift:187/202/219` — 28×28, 24×24, 32×32
- `InsightsView.swift:71` — 34×34
- `WeekStrip.swift:191` — 13×13

Apple's minimum is 44×44pt. A view can stay visually small and still meet it with
`.contentShape` and padding, so this is cheap to fix and worth doing early.

---

## What I could not measure without a device

Smoothness and dropped frames · whether Liquid Glass already appears on the native chrome ·
gesture feel and any iOS 26 scroll/drag regressions · VoiceOver reading order · whether layouts
survive accessibility text sizes · specular highlights (these do not render correctly in the
simulator, so **CI can never verify the visual layer** — every appearance change needs an on-device
pass).
