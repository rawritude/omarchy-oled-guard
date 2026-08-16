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
  content underneath. Dimming a film is a bug, not a feature.
- **Wear accounting** — tracks how much lit time it has actually reclaimed, so
  the plugin can be judged on numbers instead of vibes.

It follows the bar: change `bar.position` to `left` and the veil moves to the
left edge, resize the bar and the veil resizes with it. Hide the bar entirely
and the veil stops drawing, because there is nothing left to protect.

## Two attenuation modes

**Flat dim** (default) applies uniform alpha across the strip.

**Checkerboard** (`"checkerboard": true`) tiles a 2×2 pattern so half the
pixels take double the attenuation and the other half take none, rotating the
phase every `checkerPhaseMinutes` so the pattern itself cannot etch in. Same
average wear reduction, spent differently: deeper rest for the covered pixels,
at the cost of visible texture on the bar.

Flat dim is the better default precisely *because* alpha compositing is
available here. The existing Hyprland tool in this space,
[hyproled](https://github.com/mklan/hyproled), uses a checkerboard shader
because a shader can only switch pixels fully off — it has no way to ask for
"70% as bright". A QML overlay does, so it can reach the same wear target
without throwing away contrast. The checkerboard mode is kept for people who
want maximum protection and do not mind the texture.

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
omarchy plugin add https://github.com/<you>/omarchy-oled-guard.git --enable
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
`omarchy restart shell`.

## Bar indicator

Optional. `●` guarding · `◐` awake but not attenuating · `○` paused. Click to
toggle pause. Set `"showSaved": true` to display reclaimed hours next to it —
off by default, because a plugin whose job is to light fewer pixels should not
insist on lighting more of them to say so.

## Control

```bash
omarchy-shell oledguard status    # JSON: state, geometry, accumulated stats
omarchy-shell oledguard pause     # lift the veil for now
omarchy-shell oledguard resume
omarchy-shell oledguard toggle
omarchy-shell oledguard flush     # force stats to disk
omarchy-shell oledguard reset     # zero the accumulated stats
```

Pause is deliberately not persisted — it means "not right now". For "not ever",
set `"enabled": false`.

## Wear accounting

Stats live in `~/.local/state/omarchy/oled-guard.json`:

| field | meaning |
|---|---|
| `panelSeconds` | shell uptime observed |
| `guardedSeconds` | time the veil was actually attenuating |
| `savedSeconds` | attenuation-weighted lit time avoided on the strip |

`savedSeconds` is the honest figure: attenuation × duration, integrated. At
`baseOpacity: 0.4` held for a minute it records 24 seconds, because that is the
emitted-light-seconds the strip did not spend. Written every five minutes
rather than every minute, so a session that ends abruptly can lose up to five
minutes of accounting.

## Requirements

Omarchy 4.x (Quickshell-based shell). No external dependencies.

## Licence

MIT
