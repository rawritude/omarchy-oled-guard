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

    // Asymmetric on purpose. Clearing the veil answers a gesture you just made,
    // so it has to feel immediate; putting it back is unprompted, so it should
    // be slow enough that you never catch it happening. One duration for both
    // makes you choose between a sluggish reveal and a visibly blinking bar.
    fadeMs: 700,
    revealMs: 170,

    // Texture mode: a flat floor across the strip plus a shallow checker over
    // half of it, rotating so the pattern cannot etch itself in.
    //
    // It does NOT save more wear than a plain flat dim. At equal average the
    // two are level under a linear model and worse under realistic superlinear
    // ageing, because splitting an average into extremes costs more than
    // holding the middle. It is a look, kept cheap; see veilLayers.
    checkerboard: false,
    checkerPhaseMinutes: 5,

    // Depth of the checker layer, over a flat floor that carries the rest of
    // the requested attenuation. Kept modest on purpose: the wear penalty for
    // texture rises steeply with this and with nothing else, so 0.25 buys a
    // clearly visible pattern for about 2% over flat dim, where the old
    // no-floor behaviour (effectively 2x the attenuation) cost 11%.
    checkerContrast: 0.25,

    // Lift the veil while the pointer is on the bar, the way omarchy's own
    // indicators reveal themselves on hover.
    //
    // This is the setting that makes deep attenuation practical. A bar you must
    // read at a glance can only be dimmed so far; a bar that clears the moment
    // you reach for it can sit at 85% attenuation all day, which is a different
    // order of saving. It also beats hiding the bar outright: nothing to
    // discover, nothing to undo.
    revealOnHover: false,
    hoverOpacity: 0.0,

    // Never attenuate over fullscreen content -- dimming a film is a bug.
    suspendOnFullscreen: true
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
        revealMs: Math.round(clamp(asNumber(src.revealMs, DEFAULTS.revealMs), 0, 10000)),
        checkerboard: asBool(src.checkerboard, DEFAULTS.checkerboard),
        checkerPhaseMinutes: Math.round(clamp(asNumber(src.checkerPhaseMinutes, DEFAULTS.checkerPhaseMinutes), 1, 720)),
        checkerContrast: clamp(asNumber(src.checkerContrast, DEFAULTS.checkerContrast), 0.05, 1),
        revealOnHover: asBool(src.revealOnHover, DEFAULTS.revealOnHover),
        hoverOpacity: clamp(asNumber(src.hoverOpacity, DEFAULTS.hoverOpacity), 0, 0.9),
        suspendOnFullscreen: asBool(src.suspendOnFullscreen, DEFAULTS.suspendOnFullscreen)
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
    // A lock surface covers the bar entirely, so there is nothing underneath
    // worth veiling and no reason to keep compositing one.
    if (!state.lit)
        return 0
    // Hover wins over idle: reaching for the bar is input, so the two cannot
    // truthfully be in conflict, and resolving it here keeps the reveal instant
    // rather than waiting on the idle monitor to catch up.
    if (state.revealOnHover && state.hovered)
        return state.hoverOpacity
    return state.idle ? state.idleOpacity : state.baseOpacity
}

// The two stacked veils the overlay paints: a flat floor across the whole
// strip, and a checker of depth `k` over half of it. Black veils composite
// multiplicatively, so
//
//     uncovered drive = (1 - floor)
//     covered   drive = (1 - floor)(1 - k)
//     average         = (1 - floor)(1 - k/2)
//
// Solving that for a requested average attenuation `a` gives the floor below.
//
// Why not simply paint the checker at 2a with no floor, which also hits the
// average? Because wear goes as L^gamma with gamma above 1, so the penalty for
// splitting an average into extremes depends only on k -- the floor term
// cancels out of the ratio entirely. Concretely, at gamma 2: k=0.5 with no
// floor costs +11% over flat dim, while k=0.25 over a floor costs +2% for the
// same average and the same visible texture. The no-floor version is the worst
// available way to draw a checkerboard, and it is what this used to do.
//
// It also leaves half the pixels at full drive. Keeping a floor caps peak drive
// too, which is the part the L^gamma model does not even charge for.
function veilLayers(attenuation, checkerboard, checkerContrast) {
    var a = clamp(asNumber(attenuation, 0), 0, 1)
    if (!checkerboard || a <= 0)
        return { floor: a, checker: 0 }

    // A checker of depth k costs k/2 of average attenuation on its own. It
    // cannot be deeper than the budget allows, or the floor would go negative.
    var k = clamp(asNumber(checkerContrast, 0.25), 0, 1)
    k = Math.min(k, a * 2)

    var floor = 1 - (1 - a) / (1 - k / 2)
    return { floor: clamp(floor, 0, 1), checker: k }
}

// What the panel actually receives on average -- the only figure fit to report
// or to bank.
//
// Constructed to equal the request, so unlike the old no-floor checkerboard
// there is no silent ceiling: the floor absorbs whatever depth the checker
// cannot carry, at any requested attenuation.
function effectiveAttenuation(attenuation, checkerboard, checkerContrast) {
    var layers = veilLayers(attenuation, checkerboard, checkerContrast)
    return clamp(1 - (1 - layers.floor) * (1 - layers.checker / 2), 0, 1)
}

// Checkerboard phase walks the four alignments of a 2x2 tile, so over a full
// cycle every pixel in the strip has spent equal time lit and unlit.
// A checkerboard has exactly two states, not four.
//
// The tile is opaque on its diagonal, so offsetting by (1,1) maps black onto
// black and reproduces the original pattern: a four-step walk over
// (0,0),(1,0),(0,1),(1,1) actually renders P, P', P', P. Total time came out
// even, so wear levelling still worked, but each state was held for two
// consecutive intervals instead of alternating, and the phase period was
// effectively double what the setting said.
//
// Two phases, strictly alternating, is what the geometry supports.
function phaseOffset(phase) {
    var p = ((phase % 2) + 2) % 2
    return { x: p, y: 0 }
}
