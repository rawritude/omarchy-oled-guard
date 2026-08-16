# OLED Guard

An [Omarchy](https://omarchy.org/) shell plugin that stops your status bar from
out-wearing the rest of your OLED panel.

## The problem

OLED wear is luminance integrated over time. On a desktop, almost every pixel
gets shuffled constantly — windows move, text scrolls, workspaces switch. One
surface does not: the bar. The clock, the tray icons, the workspace pills sit in
the same physical pixels for the entire life of the session. Over enough hours
that strip simply ages faster than the panel around it, and the result is a
faint permanent band across the top of the screen.

Manufacturer guidance for this is consistent and boring: hide static UI, keep
brightness sane, let the screen switch off. OLED Guard covers the case those
leave open — the hours you are actually *using* the machine and want the bar
visible.

## What it does

Holds a translucent veil over the bar strip, and only the bar strip.

- **Continuous attenuation** (`baseOpacity`) — a standing reduction in how hard
  the bar's pixels are driven while you work.
- **Idle attenuation** (`idleOpacity`) — deepens once there has been no input
  for `idleAfterSeconds`, and lifts the instant you touch anything.
- **Fullscreen suspend** — the veil lifts entirely when there is fullscreen
  content underneath. Dimming a film is a bug, not a feature. Decided per
  monitor, so a film on one screen is not veiled because another screen
  happens to hold focus.
- **Wear accounting** — tracks how much lit time it has actually reclaimed, so
  the plugin can be judged on numbers instead of vibes.

It follows the bar: change `bar.position` to `left` and the veil moves to the
left edge, resize the bar and the veil resizes with it. Hide the bar entirely
and the veil stops drawing, because there is nothing left to protect.

## Two attenuation modes

**Flat dim** (default) applies uniform alpha across the strip.

**Checkerboard** (`"checkerboard": true`) tiles a 2×2 pattern so half the strip
is covered at double alpha and the other half not at all, rotating the phase
every `checkerPhaseMinutes` so the pattern itself cannot etch in.

**It does not save more wear than flat dim.** At equal average the two are
level under a linear model, and checkerboard is slightly *worse* under
realistic OLED aging, which is superlinear in drive level: phase rotation
leaves every pixel at full drive half the time, and for a convex wear curve the
average of the two extremes exceeds the middle. It is offered for people who
want the deep-rest behaviour, not as an upgrade — which is the other reason
flat dim is the default.

Two further limits:

- **It cannot exceed 50% average attenuation.** The mode doubles alpha over
  half the pixels, and alpha saturates at 1.0, so anything above `0.5` caps
  out. The plugin reports this honestly rather than quietly booking the number
  you asked for — `status` returns both `requestedAttenuation` and the
  `attenuation` actually delivered, and only the delivered figure is banked.
- **The cell size follows your display scale.** The tile is 2×2 *logical*
  pixels, so at scale 2 each cell covers a 2×2 block of physical pixels rather
  than one. Coverage is still 50% and rotation still swaps the covered set
  completely, so the arithmetic holds, but the texture is coarser than a true
  one-pixel checker. At fractional scales (1.25, 1.5) nearest-neighbour
  scaling makes cells uneven and the equal-time property degrades.

Flat dim is available at all here only because this is a compositing layer. The
existing Hyprland tool in this space,
[hyproled](https://github.com/mklan/hyproled), uses a checkerboard shader
because a shader can only switch pixels fully off — it has no way to ask for
"70% as bright". A QML overlay can, which is why the default here is the mode
hyproled could not offer.

## What this plugin deliberately does not do

**It does not orbit or nudge the bar.** Pixel-shift is the reflex suggestion
for burn-in, and for a status bar it is largely theatre: sliding a uniform
block two pixels sideways only changes the two-pixel edge, while the static
block stays exactly as static. It also isn't available — a plugin cannot
translate another plugin's layer-shell surface. Reducing how hard the strip is
driven attacks the actual wear term; moving it slightly does not.

**It is not a replacement for the boring advice.** Lower brightness and a short
display-off timeout beat this plugin on effort-to-benefit. Do those first. And
worth keeping in proportion: a
[3000-hour burn-in test](https://www.notebookcheck.net/3000-hour-LG-OLED-monitor-burn-in-test-reveals-minor-defects-with-Overwatch-2-a-culprit.1221804.0.html)
found modern panels hold up well, with damage concentrated in high-contrast
static elements. A status bar is exactly that shape, which is why this exists —
but it is insurance, not an emergency.

## Install

```bash
omarchy plugin add https://github.com/rawritude/omarchy-oled-guard.git --enable
```

Then restart the shell so the plugin's JS library loads:

```bash
omarchy restart shell
```

Enabling adds an entry to `~/.config/omarchy/shell.json`. The plugin ships both
a background service and an optional bar indicator, and reads its config from
whichever entry exists — the `bar.layout` entry if you enabled the widget, or a
`plugins[]` entry if you want the service without the indicator.

## Configuration

All keys are optional; the defaults below are what you get with an empty entry.

```jsonc
{
  "id": "oled.guard",

  "enabled": true,             // false disables without uninstalling
  "baseOpacity": 0.0,          // 0.0-0.9  standing attenuation while active
  "idleOpacity": 0.5,          // 0.0-0.95 attenuation once idle
  "idleAfterSeconds": 90,      // 5-3600
  "fadeMs": 1500,              // transition length; 0 for instant

  "checkerboard": false,       // true swaps flat dim for the rotating pattern
  "checkerPhaseMinutes": 5,    // 1-720

  "suspendOnFullscreen": true, // lift the veil over fullscreen content
  "tracking": true,            // record reclaimed lit time

  "showSaved": false           // bar widget only: show the reclaimed figure
}
```

`baseOpacity` defaults to `0.0` — out of the box the guard only acts on idle,
so nothing about your bar changes while you are looking at it. Raise it to
`0.15`–`0.25` for a standing reduction that is easy to stop noticing.

Config changes hot-reload. Editing the plugin's `.js` requires
`omarchy restart shell` (plugin code is cached, `.qml` and `.js` alike).

## Bar indicator and panel

A Nerd Font shield matching the first-party bar indicators: half-full while
attenuating, outline while standing by, struck through when paused.

**Left click opens a panel** — protection level, depth, and the reclaimed-time
figure, so nothing here needs hand-editing `shell.json`. **Right click** pauses
and resumes without opening anything.

```
  PROTECTION   Off  ·  Dim  ·  Checker
  DEPTH        Light  ·  Medium  ·  Deep
  BAR          Hide the bar
```

Depth is presets rather than raw opacities, because "how protected do you want
to be" is the question people actually have. Light is 10%/40%, Medium 15%/55%,
Deep 25%/75% — working and idle respectively.

The **Hide the bar** row sits deliberately beside the attenuation controls: not
drawing the bar beats attenuating it, Omarchy already ships that toggle, and
the two belong next to each other rather than in separate places.

This panel is the one file that imports Omarchy's internal `qs.*` UI module, so
it matches every other dropdown. The service and the overlay stay
dependency-free — if a future Omarchy release moves that module, the indicator
is what breaks, never the guarding.

## Control

```bash
omarchy-shell oledguard status    # JSON: state, geometry, accumulated stats
omarchy-shell oledguard pause     # lift the veil for now
omarchy-shell oledguard resume
omarchy-shell oledguard toggle
omarchy-shell oledguard flush     # force stats to disk
omarchy-shell oledguard reset     # zero the accumulated stats
```

The panel exposes the same choices, so they can go on a keybinding:

```bash
omarchy-shell oled.guard mode off|dim|checker
omarchy-shell oled.guard depth light|medium|deep
omarchy-shell oled.guard toggle   # open/close the panel
omarchy-shell oled.guard state
```

Pause is deliberately not persisted — it means "not right now". For "not ever",
set `"enabled": false`.

## Wear accounting

Stats live in `~/.local/state/omarchy/oled-guard.json`:

| field | meaning |
|---|---|
| `panelSeconds` | time the panel was actually lit: awake, unlocked, shell up |
| `guardedSeconds` | of that, time the veil was actually attenuating |
| `savedSeconds` | attenuation-weighted lit time avoided on the strip |

`savedSeconds` integrates delivered attenuation × duration. At `baseOpacity:
0.4` held for a minute it records 24 seconds.

What it deliberately refuses to count:

- **Time the panel was not emitting.** A locked session or a slept display
  advances nothing at all. Counting those would let an overnight idle inflate
  the totals toward `idleOpacity` regardless of what the guard did.
- **Attenuation it did not actually deliver.** In checkerboard mode above
  `0.5`, the delivered average is banked, not the configured one.

Two known limits: the estimate is **conservative** — alpha composites in gamma
space, so black at alpha 0.4 cuts linear luminance by rather more than 40%, and
under-claiming is the right direction here. And accounting is sampled once a
minute at the attenuation prevailing at the tick, so brief transitions are
approximated. Stats are written every five minutes and on shutdown.

## Requirements

Omarchy 4.x (Quickshell-based shell). No external dependencies.

## Licence

MIT
