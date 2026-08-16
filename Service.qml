import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "GuardModel.js" as GuardModel

// OLED Guard.
//
// The premise: on an OLED panel, wear is luminance integrated over time, and
// the status bar is the only surface that holds still for the entire session.
// Every other pixel gets shuffled by window moves, scrolling and workspace
// switches; the bar's clock, tray icons and workspace pills do not. Left alone
// the strip simply ages faster than the panel around it.
//
// So the guard does one thing and reports on it honestly: hold a translucent
// veil over that strip, deepen it when nobody is looking, lift it entirely
// when there is fullscreen content underneath, and keep a running total of the
// lit time it has actually clawed back.
Item {
    id: root

    // Injected by omarchy-shell's service loader.
    property var shell: null
    property string omarchyPath: ""
    property var manifest: null

    readonly property string home: Quickshell.env("HOME")
    readonly property string statsPath: home + "/.local/state/omarchy/oled-guard.json"

    readonly property var config: GuardModel.normalize(
        GuardModel.entryFor(shell ? shell.shellConfig : null, GuardModel.PLUGIN_ID))

    // Runtime pause, driven by IPC or the bar widget. Deliberately not
    // persisted: a pause is for "not right now", not for "forever" -- forever
    // is `"enabled": false` in shell.json.
    property bool paused: false

    property bool idle: false
    property bool fullscreen: false
    property int phase: 0

    property var stats: GuardModel.emptyStats()
    property bool statsLoaded: false

    // --------------------------------------------------------------- geometry
    //
    // Taken off the live bar rather than re-derived from hyprctl: the bar host
    // already knows its own edge and thickness, and reading it here means a
    // bar that resizes or moves drags the veil along with it for free.
    readonly property var barConfig: shell ? shell.barConfig : null
    readonly property string edge: GuardModel.edgeFor(barConfig)
    readonly property int barThickness: shell && shell.bar && shell.bar.barSize > 0 ? shell.bar.barSize : 26
    readonly property bool barHidden: shell && shell.bar ? !!shell.bar.barHidden : false

    // ------------------------------------------------------------ attenuation
    readonly property real attenuation: GuardModel.attenuationFor({
        enabled: config.enabled,
        paused: root.paused,
        barHidden: root.barHidden,
        suspendOnFullscreen: config.suspendOnFullscreen,
        fullscreen: root.fullscreen,
        idle: root.idle,
        baseOpacity: config.baseOpacity,
        idleOpacity: config.idleOpacity
    })

    readonly property bool active: attenuation > 0

    function statusObject() {
        return {
            enabled: config.enabled,
            paused: root.paused,
            active: root.active,
            attenuation: Math.round(root.attenuation * 100) / 100,
            mode: config.checkerboard ? "checkerboard" : "dim",
            idle: root.idle,
            fullscreen: root.fullscreen,
            edge: root.edge,
            thickness: root.barThickness,
            panelHours: GuardModel.formatHours(root.stats.panelSeconds),
            guardedHours: GuardModel.formatHours(root.stats.guardedSeconds),
            savedHours: GuardModel.formatHours(root.stats.savedSeconds),
            savedFraction: Math.round(GuardModel.savedFraction(root.stats) * 1000) / 1000
        }
    }

    // ------------------------------------------------------------- fullscreen
    //
    // Read off the focused workspace's raw hyprctl payload. Guarded rather than
    // bound directly: the shape of lastIpcObject is Hyprland's, not ours, and a
    // missing key here must not take the shell down with it.
    function refreshFullscreen() {
        if (!config.suspendOnFullscreen) {
            root.fullscreen = false
            return
        }
        var value = false
        try {
            var ws = Hyprland.focusedWorkspace
            var raw = ws ? ws.lastIpcObject : null
            if (raw)
                value = !!(raw.hasfullscreen || raw.hasFullscreen)
        } catch (e) {
            value = false
        }
        root.fullscreen = value
    }

    Connections {
        target: Hyprland
        ignoreUnknownSignals: true

        function onFocusedWorkspaceChanged() {
            root.refreshFullscreen()
        }

        function onRawEvent(event) {
            // Cheap filter: only the events that can flip fullscreen state are
            // worth a workspace refresh, and this fires on every Hyprland event.
            var name = ""
            try {
                name = String(event.name || "")
            } catch (e) {
                return
            }
            if (name === "fullscreen" || name === "activewindow" || name === "closewindow"
                    || name === "openwindow" || name === "workspace") {
                Hyprland.refreshWorkspaces()
                root.refreshFullscreen()
            }
        }
    }

    // ------------------------------------------------------------------- idle
    IdleMonitor {
        id: idleMonitor
        enabled: root.config.enabled && !root.paused
        timeout: root.config.idleAfterSeconds
        respectInhibitors: true
        onIsIdleChanged: root.idle = isIdle
    }

    // Rotating the checkerboard phase is what stops the pattern itself from
    // becoming the burn-in. Pointless in flat-dim mode, so it does not run.
    Timer {
        id: phaseTimer
        running: root.config.enabled && root.config.checkerboard
        interval: root.config.checkerPhaseMinutes * 60 * 1000
        repeat: true
        onTriggered: root.phase = (root.phase + 1) % 4
    }

    // --------------------------------------------------------------- tracking
    readonly property int trackIntervalSeconds: 60

    // Accounting happens every minute but only reaches disk every fifth one.
    // This service runs for the entire life of the session; a write per minute
    // forever is a lot of needless flash churn to record a counter nobody
    // reads more than once a week.
    readonly property int persistEveryTicks: 5
    property int ticksSincePersist: 0

    function persistStats() {
        ticksSincePersist = 0
        statsFile.setText(JSON.stringify(root.stats, null, 2) + "\n")
    }

    Timer {
        id: trackTimer
        running: root.config.tracking && root.statsLoaded
        interval: root.trackIntervalSeconds * 1000
        repeat: true
        onTriggered: {
            root.stats = GuardModel.accumulate(root.stats, root.trackIntervalSeconds, root.attenuation)
            root.ticksSincePersist++
            if (root.ticksSincePersist >= root.persistEveryTicks)
                root.persistStats()
        }
    }

    FileView {
        id: statsFile
        path: root.statsPath
        atomicWrites: true
        printErrors: false

        onLoaded: {
            var parsed = null
            try {
                parsed = JSON.parse(text() || "{}")
            } catch (e) {
                parsed = null
            }
            root.stats = GuardModel.normalizeStats(parsed)
            root.statsLoaded = true
        }

        // No file yet is the normal first run, not a problem to report.
        onLoadFailed: function (error) {
            root.stats = GuardModel.emptyStats()
            root.statsLoaded = true
        }
    }

    // On a first run there is no stats file, and a FileView pointed at a path
    // that does not exist can settle without signalling either way. Without
    // this the load never resolves, statsLoaded stays false, and the tracking
    // timer that gates on it never starts -- so the guard would run forever
    // and never record a single second of it.
    Timer {
        id: statsLoadFallback
        interval: 2000
        repeat: false
        running: !root.statsLoaded
        onTriggered: {
            if (root.statsLoaded)
                return
            root.stats = GuardModel.emptyStats()
            root.statsLoaded = true
        }
    }

    // ---------------------------------------------------------------- surface
    Variants {
        model: Quickshell.screens

        Overlay {
            edge: root.edge
            thickness: root.barThickness
            attenuation: root.attenuation
            checkerboard: root.config.checkerboard
            phaseX: GuardModel.phaseOffset(root.phase).x
            phaseY: GuardModel.phaseOffset(root.phase).y
            fadeMs: root.config.fadeMs
        }
    }

    // -------------------------------------------------------------------- IPC
    IpcHandler {
        target: "oledguard"

        function status(): string {
            return JSON.stringify(root.statusObject())
        }

        function pause(): string {
            root.paused = true
            return "paused"
        }

        function resume(): string {
            root.paused = false
            return "resumed"
        }

        function toggle(): string {
            root.paused = !root.paused
            return root.paused ? "paused" : "resumed"
        }

        function reset(): string {
            root.stats = GuardModel.emptyStats()
            root.persistStats()
            return "reset"
        }

        // Force the in-memory tally to disk. Worth having because the periodic
        // write lags by up to five minutes, and anything reading the stats file
        // directly deserves a way to see current numbers.
        function flush(): string {
            root.persistStats()
            return GuardModel.formatHours(root.stats.panelSeconds)
        }
    }

    Component.onCompleted: {
        refreshFullscreen()
        statsFile.reload()
    }
}
