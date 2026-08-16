.pragma library

// Pure logic for OLED Guard. No QML types in here on purpose: every function
// below is a plain value transform, so the behaviour that actually matters
// (what attenuation applies right now, how much wear that saved) can be
// reasoned about without a running shell.

var PLUGIN_ID = "oled.guard"

var DEFAULTS = {
    enabled: true,

    // Attenuation applied to the bar strip whenever the guard is awake. The
    // bar is the one surface that holds still for the whole session, so this
    // is the number that decides whether it out-wears the rest of the panel.
    // 0 keeps the bar at full brightness; the guard then only acts on idle.
    baseOpacity: 0.0,

    // Deeper attenuation once there has been no input for idleAfterSeconds.
    idleOpacity: 0.5,
    idleAfterSeconds: 90,

    fadeMs: 1500,

    // Hard mode: instead of a flat dim, tile a checkerboard so half the strip
    // is covered at double alpha, rotating the phase so the pattern itself
    // cannot etch in.
    //
    // It does NOT save more wear than flat dim. At equal average it is level
    // under a linear model, and slightly worse under realistic superlinear
    // aging: rotation leaves each pixel at full drive half the time, and for a
    // convex wear curve the average of the extremes exceeds the middle. It is
    // offered for people who want the deep-rest behaviour, not as an upgrade.
    checkerboard: false,
    checkerPhaseMinutes: 5,

    // Never attenuate over fullscreen content -- dimming a film is a bug.
    suspendOnFullscreen: true,

    tracking: true
}

var EDGES = ["top", "bottom", "left", "right"]

function clamp(value, lo, hi) {
    if (!isFinite(value))
        return lo
    return value < lo ? lo : (value > hi ? hi : value)
}

function asNumber(value, fallback) {
    if (value === undefined || value === null)
        return fallback
    var n = Number(value)
    return isFinite(n) ? n : fallback
}

function asBool(value, fallback) {
    if (value === undefined || value === null)
        return fallback
    return !!value
}

function _findInList(list, wanted) {
    if (!list || !Array.isArray(list))
        return null
    for (var i = 0; i < list.length; i++) {
        var entry = list[i]
        if (entry && String(entry.id) === wanted)
            return entry
    }
    return null
}

// Locate this plugin's entry in shell.json, wherever the user happened to
// enable it from.
//
// A plugin declaring both `service` and `bar-widget` can legitimately be
// listed in either place: `omarchy plugin enable` drops a widget into
// bar.layout, while a service-only install goes in plugins[]. Both are the
// same plugin and both should configure the same service, so look in both --
// plugins[] first, since that is the explicit service registration.
function entryFor(shellConfig, id) {
    if (!shellConfig)
        return null
    var wanted = String(id || PLUGIN_ID)

    var found = _findInList(shellConfig.plugins, wanted)
    if (found)
        return found

    var layout = shellConfig.bar && shellConfig.bar.layout ? shellConfig.bar.layout : null
    if (!layout)
        return null
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
        found = _findInList(layout[sections[s]], wanted)
        if (found)
            return found
    }
    return null
}

function normalize(raw) {
    var src = raw || {}
    return {
        enabled: asBool(src.enabled, DEFAULTS.enabled),
        baseOpacity: clamp(asNumber(src.baseOpacity, DEFAULTS.baseOpacity), 0, 0.9),
        idleOpacity: clamp(asNumber(src.idleOpacity, DEFAULTS.idleOpacity), 0, 0.95),
        idleAfterSeconds: Math.round(clamp(asNumber(src.idleAfterSeconds, DEFAULTS.idleAfterSeconds), 5, 3600)),
        fadeMs: Math.round(clamp(asNumber(src.fadeMs, DEFAULTS.fadeMs), 0, 10000)),
        checkerboard: asBool(src.checkerboard, DEFAULTS.checkerboard),
        checkerPhaseMinutes: Math.round(clamp(asNumber(src.checkerPhaseMinutes, DEFAULTS.checkerPhaseMinutes), 1, 720)),
        suspendOnFullscreen: asBool(src.suspendOnFullscreen, DEFAULTS.suspendOnFullscreen),
        tracking: asBool(src.tracking, DEFAULTS.tracking)
    }
}

function edgeFor(barConfig) {
    var position = barConfig && barConfig.position ? String(barConfig.position) : "top"
    return EDGES.indexOf(position) === -1 ? "top" : position
}

function isVerticalEdge(edge) {
    return edge === "left" || edge === "right"
}

// The single decision the overlay renders. Kept as one function so the
// precedence between "paused", "bar is hidden", "the panel is not even lit"
// and "user went idle" is stated once rather than smeared across bindings.
//
// Fullscreen is deliberately NOT handled here: it is a per-monitor fact, and
// resolving it globally would veil a film on one screen because a different
// screen happens to hold focus. Each overlay decides that for its own screen.
function attenuationFor(state) {
    if (!state.enabled || state.paused)
        return 0
    if (state.barHidden)
        return 0
    // A locked session covers the bar, and a slept panel emits nothing. Veiling
    // either is pointless, and -- the reason this matters -- banking "wear
    // avoided" for pixels that were dark or unpowered would make the headline
    // number drift toward idleOpacity no matter what the guard actually did.
    if (!state.lit)
        return 0
    return state.idle ? state.idleOpacity : state.baseOpacity
}

// What the overlay paints. Checkerboard covers half the strip, so it doubles
// alpha to hit the same average as a flat dim of the same depth.
function veilOpacity(attenuation, checkerboard) {
    var a = clamp(asNumber(attenuation, 0), 0, 1)
    return checkerboard ? clamp(a * 2, 0, 1) : a
}

// What the panel actually receives on average -- the only figure fit to report
// or to bank.
//
// These diverge in checkerboard mode above 0.5: alpha saturates at 1.0, so the
// delivered average caps at 0.5 however deep the config asked for. Booking the
// requested value there would overstate the saving by up to 1.9x, in the mode
// most likely to be chosen by someone who cares about the number.
function effectiveAttenuation(attenuation, checkerboard) {
    var painted = veilOpacity(attenuation, checkerboard)
    return checkerboard ? painted / 2 : painted
}

// Checkerboard phase walks the four alignments of a 2x2 tile, so over a full
// cycle every pixel in the strip has spent equal time lit and unlit.
function phaseOffset(phase) {
    var p = ((phase % 4) + 4) % 4
    return {
        x: p === 1 || p === 3 ? 1 : 0,
        y: p === 2 || p === 3 ? 1 : 0
    }
}

function emptyStats() {
    return {
        version: 1,
        panelSeconds: 0, // time the panel was lit: awake, unlocked, shell up
        guardedSeconds: 0, // of that, time the guard was actually attenuating
        savedSeconds: 0 // attenuation-weighted lit time avoided on the strip
    }
}

function normalizeStats(raw) {
    var base = emptyStats()
    if (!raw || typeof raw !== "object")
        return base
    base.panelSeconds = Math.max(0, asNumber(raw.panelSeconds, 0))
    base.guardedSeconds = Math.max(0, asNumber(raw.guardedSeconds, 0))
    base.savedSeconds = Math.max(0, asNumber(raw.savedSeconds, 0))
    return base
}

// One tick of wear accounting.
//
// `attenuation` must be the *delivered* average (see effectiveAttenuation), and
// `lit` must be false whenever the panel was not actually emitting -- asleep,
// or covered by the lock surface. A tick that is not lit advances nothing at
// all, so an overnight idle cannot inflate the totals.
//
// attenuation * seconds is a deliberately conservative estimate of the
// emitted-light-seconds avoided: alpha composites in gamma space, so black at
// alpha 0.4 cuts linear luminance by rather more than 40%. Under-claiming is
// the right direction for a number the README asks anyone to trust.
function accumulate(stats, deltaSeconds, attenuation, lit) {
    var next = normalizeStats(stats)
    if (!lit)
        return next
    var delta = Math.max(0, asNumber(deltaSeconds, 0))
    var alpha = clamp(asNumber(attenuation, 0), 0, 1)
    next.panelSeconds += delta
    if (alpha > 0) {
        next.guardedSeconds += delta
        next.savedSeconds += delta * alpha
    }
    return next
}

function formatHours(seconds) {
    var hours = Math.max(0, asNumber(seconds, 0)) / 3600
    if (hours < 1)
        return Math.round(hours * 60) + "m"
    if (hours < 100)
        return (Math.round(hours * 10) / 10) + "h"
    return Math.round(hours) + "h"
}

// Share of the strip's lit time this guard has clawed back. This is the number
// worth reporting: it is what separates "the bar is dimmer" from "the bar is
// ageing at the same rate as the rest of the panel".
function savedFraction(stats) {
    var s = normalizeStats(stats)
    if (s.panelSeconds <= 0)
        return 0
    return clamp(s.savedSeconds / s.panelSeconds, 0, 1)
}
