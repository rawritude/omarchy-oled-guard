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

    // Hard mode: instead of a flat dim, tile a checkerboard so half the
    // subpixels in the strip are fully off, and rotate its phase so the
    // pattern itself cannot etch in. Costs contrast; wins more wear.
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
// precedence between "paused", "bar is hidden", "something is fullscreen" and
// "user went idle" is stated once rather than smeared across bindings.
function attenuationFor(state) {
    if (!state.enabled || state.paused)
        return 0
    if (state.barHidden)
        return 0
    if (state.suspendOnFullscreen && state.fullscreen)
        return 0
    return state.idle ? state.idleOpacity : state.baseOpacity
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
        panelSeconds: 0, // shell uptime with at least one screen awake
        guardedSeconds: 0, // time the guard was actually attenuating
        savedSeconds: 0 // attenuation-weighted wear avoided on the strip
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

// One tick of wear accounting. `attenuation` is the alpha currently over the
// strip, so attenuation * seconds is the emitted-light-seconds it avoided --
// the honest unit here, since OLED wear tracks luminance integrated over time.
function accumulate(stats, deltaSeconds, attenuation) {
    var next = normalizeStats(stats)
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
