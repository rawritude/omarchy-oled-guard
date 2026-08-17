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
    property int phase: 0

    // Bumped whenever something happened that could change a per-screen
    // fullscreen verdict. Overlays reference it so their own bindings
    // re-evaluate: `lastIpcObject` is refreshed in place by an async round
    // trip, and a binding on it alone would not reliably re-run.
    property int hyprRevision: 0

    // Is the panel actually emitting? Two ways for it not to be, and both
    // otherwise let the stats accrue "wear avoided" against dark pixels.
    property bool displayAwake: true
    readonly property bool locked: {
        try {
            var lock = shell && typeof shell.serviceFor === "function"
                ? shell.serviceFor("omarchy.lock") : null
            return lock ? !!lock.locked : false
        } catch (e) {
            return false
        }
    }
    readonly property bool lit: displayAwake && !locked

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
    //
    // Screen-independent part only. Fullscreen is resolved per overlay, since
    // it is a per-monitor fact.
    readonly property real attenuation: GuardModel.attenuationFor({
        enabled: config.enabled,
        paused: root.paused,
        barHidden: root.barHidden,
        lit: root.lit,
        idle: root.idle,
        baseOpacity: config.baseOpacity,
        idleOpacity: config.idleOpacity
    })

    // What the panel receives on average, once checkerboard's alpha ceiling is
    // taken into account. This is the figure that gets reported and banked.
    readonly property real deliveredAttenuation: GuardModel.effectiveAttenuation(
        root.attenuation, config.checkerboard, config.checkerContrast)

    readonly property bool active: attenuation > 0

    function statusObject() {
        return {
            enabled: config.enabled,
            paused: root.paused,
            active: root.active,
            // requested is what the config asked for; delivered is what the
            // panel gets. Equal by construction now that the checker sits on a
            // floor rather than carrying the whole attenuation itself, but both
            // are reported so a future mode that cannot hit its target has
            // somewhere honest to say so.
            attenuation: Math.round(root.deliveredAttenuation * 100) / 100,
            requestedAttenuation: Math.round(root.attenuation * 100) / 100,
            mode: config.checkerboard ? "checkerboard" : "dim",
            idle: root.idle,
            lit: root.lit,
            locked: root.locked,
            displayAwake: root.displayAwake,
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
    // Only for `status` and the bar tooltip: it reports the focused screen.
    // The veil decision is made per overlay, against its own screen.
    readonly property bool fullscreen: {
        hyprRevision // re-evaluate when the workspace payload is refreshed
        try {
            var ws = Hyprland.focusedWorkspace
            var raw = ws ? ws.lastIpcObject : null
            return raw ? !!(raw.hasfullscreen || raw.hasFullscreen) : false
        } catch (e) {
            return false
        }
    }

    Connections {
        // No ignoreUnknownSignals: if a future Quickshell renames these, the
        // failure should be loud rather than silently disabling fullscreen
        // detection and leaving the veil over somebody's film.
        target: Hyprland

        function onFocusedWorkspaceChanged() {
            root.hyprRevision++
        }

        function onRawEvent(event) {
            // Cheap filter: only the events that can flip fullscreen state are
            // worth a refresh, and this fires on every Hyprland event.
            var name = ""
            try {
                name = String(event.name || "")
            } catch (e) {
                return
            }
            if (name === "fullscreen" || name === "activewindow" || name === "closewindow"
                    || name === "openwindow" || name === "workspace"
                    || name === "focusedmon" || name === "monitoradded"
                    || name === "monitorremoved") {
                Hyprland.refreshWorkspaces()
                Hyprland.refreshMonitors()
                // refreshWorkspaces is an async round trip, so bumping here
                // only covers the pre-refresh read; the settle timer below
                // catches the state the refresh actually returned.
                root.hyprRevision++
                hyprSettleTimer.restart()
            }
        }
    }

    Timer {
        id: hyprSettleTimer
        interval: 120
        repeat: false
        onTriggered: root.hyprRevision++
    }

    // ------------------------------------------------------------------- DPMS
    //
    // Hyprland is the only thing that knows whether the panel is powered. Probed
    // on idle transitions rather than polled: it can only change around one.
    Process {
        id: dpmsProbe
        command: ["hyprctl", "monitors", "-j"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var awake = true
                try {
                    var monitors = JSON.parse(text || "[]")
                    if (Array.isArray(monitors) && monitors.length > 0) {
                        awake = false
                        for (var i = 0; i < monitors.length; i++) {
                            if (monitors[i] && monitors[i].dpmsStatus) {
                                awake = true
                                break
                            }
                        }
                    }
                } catch (e) {
                    // Unparseable output must not be read as "panel is off":
                    // that would silently stop all accounting.
                    awake = true
                }
                root.displayAwake = awake
            }
        }
    }

    function refreshDpms() {
        if (!dpmsProbe.running)
            dpmsProbe.running = true
    }

    // Hyprland blanks the panel a while after idle begins, so one probe at the
    // transition would miss it. Re-probe on a slow cadence while idle, and once
    // more on wake.
    Timer {
        id: dpmsWhileIdle
        interval: 30000
        repeat: true
        running: root.idle && root.config.tracking
        onTriggered: root.refreshDpms()
    }

    // ------------------------------------------------------------------- idle
    IdleMonitor {
        id: idleMonitor
        enabled: root.config.enabled && !root.paused
        timeout: root.config.idleAfterSeconds
        respectInhibitors: true
        onIsIdleChanged: {
            root.idle = isIdle
            root.refreshDpms()
        }
    }

    // The monitor is torn down while paused, and it is not guaranteed to
    // report going un-idle on the way out. Without this a resume could snap
    // straight to idleOpacity until the next keypress.
    onPausedChanged: if (paused) idle = false

    // Rotating the checkerboard phase is what stops the pattern itself from
    // becoming the burn-in. Pointless in flat-dim mode, so it does not run.
    Timer {
        id: phaseTimer
        running: root.config.enabled && root.config.checkerboard
        interval: root.config.checkerPhaseMinutes * 60 * 1000
        repeat: true
        onTriggered: root.phase = (root.phase + 1) % 2
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
            root.stats = GuardModel.accumulate(root.stats, root.trackIntervalSeconds,
                                               root.deliveredAttenuation, root.lit)
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
            checkerContrast: root.config.checkerContrast
            suspendOnFullscreen: root.config.suspendOnFullscreen
            hyprRevision: root.hyprRevision
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
        refreshDpms()
        statsFile.reload()
    }

    // Best effort on disable/reload, so the tally does not lose up to a full
    // persist interval every time the plugin is toggled.
    Component.onDestruction: {
        if (root.config.tracking && root.statsLoaded)
            statsFile.setText(JSON.stringify(root.stats, null, 2) + "\n")
    }
}
