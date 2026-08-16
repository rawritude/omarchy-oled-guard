import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "GuardModel.js" as GuardModel

// Bar indicator plus its dropdown.
//
// This is the one file that imports omarchy's `qs.*` UI module. That is a
// deliberate, contained bet: a dropdown built by hand would look foreign next
// to every other panel, and the alternative -- making people hand-edit
// shell.json to change protection level -- is a worse interface than no
// interface. The service and the overlay stay dependency-free, so if a future
// omarchy moves this module the indicator is what breaks, never the guarding.
Panel {
    id: root
    moduleName: "oled.guard"
    ipcTarget: "oled.guard"
    // Own the target so the panel's own verbs can share it with the base
    // open/close set -- one IpcHandler per target is the limit. Being
    // scriptable also means these choices can go on a keybinding.
    manageIpc: false

    readonly property var service: {
        try {
            if (bar && bar.shell && typeof bar.shell.serviceFor === "function")
                return bar.shell.serviceFor("oled.guard")
        } catch (e) {
            return null
        }
        return null
    }

    readonly property bool guardEnabled: setting("enabled", true) !== false
    readonly property bool guardChecker: setting("checkerboard", false) === true
    readonly property bool guardPaused: service ? !!service.paused : false
    readonly property bool guardActive: service ? !!service.active : false

    readonly property string glyphGuarding: String.fromCodePoint(0xF0780) // shield-half-full
    readonly property string glyphStandby: String.fromCodePoint(0xF099D) // shield-outline
    readonly property string glyphOff: String.fromCodePoint(0xF099E) // shield-off-outline

    readonly property string glyph: {
        if (!service || guardPaused || !guardEnabled)
            return glyphOff
        return guardActive ? glyphGuarding : glyphStandby
    }

    readonly property string modeValue: !guardEnabled ? "off" : (guardChecker ? "checker" : "dim")

    // Depth presets. Named rather than numeric because "how protected do you
    // want to be" is the question people actually have; the opacities are an
    // implementation detail they should not have to reason about.
    readonly property var depths: ({
        light: { baseOpacity: 0.10, idleOpacity: 0.40 },
        medium: { baseOpacity: 0.15, idleOpacity: 0.55 },
        deep: { baseOpacity: 0.25, idleOpacity: 0.75 }
    })

    readonly property string depthValue: {
        var base = Number(setting("baseOpacity", 0.15))
        if (base <= 0.12)
            return "light"
        if (base <= 0.20)
            return "medium"
        return "deep"
    }

    readonly property string stateLine: {
        if (!service)
            return "service not running"
        if (guardPaused)
            return "paused"
        if (!guardEnabled)
            return "off"
        if (!service.lit)
            return "panel not lit"
        if (service.fullscreen)
            return "standing by — fullscreen"
        if (guardActive)
            return "attenuating " + Math.round(service.attenuation * 100) + "%"
        return "standing by"
    }

    readonly property string savedLine: {
        if (!service || !service.stats)
            return ""
        try {
            return GuardModel.formatHours(service.stats.savedSeconds) + " of lit time reclaimed over "
                    + GuardModel.formatHours(service.stats.panelSeconds) + " lit"
        } catch (e) {
            return ""
        }
    }

    // Write back through the widget's own shell.json entry, the same way the
    // first-party clock persists a cycled format. Copy the existing keys so a
    // hand-written option we do not surface here is not silently dropped.
    //
    // Both halves are required. Assigning `settings` only updates this live
    // instance -- it is what makes the button move under the click. The
    // updateEntryInline call is what reaches shell.json, and without it the
    // choice silently reverts the next time the bar re-applies its config.
    function applySettings(patch) {
        var entry = { id: root.moduleName }
        for (var key in root.settings)
            if (key !== "id")
                entry[key] = root.settings[key]
        for (var k in patch)
            entry[k] = patch[k]
        root.settings = entry
        if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
            root.bar.shell.updateEntryInline(root.moduleName, entry)
    }

    function setMode(value) {
        if (value === "off") {
            applySettings({ enabled: false })
            return
        }
        applySettings({ enabled: true, checkerboard: value === "checker" })
        if (root.service)
            root.service.paused = false
    }

    function setDepth(value) {
        var preset = root.depths[value]
        if (preset)
            applySettings({ baseOpacity: preset.baseOpacity, idleOpacity: preset.idleOpacity })
    }

    IpcHandler {
        target: root.ipcTarget

        function open(): void { root.open() }
        function close(): void { root.close() }
        function show(): void { root.open() }
        function hide(): void { root.close() }
        function toggle(): void { root.toggle() }

        // off | dim | checker
        function mode(value: string): string {
            var v = String(value || "")
            if (v !== "off" && v !== "dim" && v !== "checker")
                return "expected off|dim|checker"
            root.setMode(v)
            return v
        }

        // light | medium | deep
        function depth(value: string): string {
            var v = String(value || "")
            if (!root.depths[v])
                return "expected light|medium|deep"
            root.setDepth(v)
            return v
        }

        function state(): string {
            return JSON.stringify({ mode: root.modeValue, depth: root.depthValue, opened: root.opened })
        }
    }

    Process { id: barToggle }

    function toggleBarVisibility() {
        if (barToggle.running)
            return
        barToggle.command = ["omarchy", "toggle", "bar"]
        barToggle.running = true
    }

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: root.glyph
        tooltipText: "OLED Guard — " + root.stateLine
        onPressed: function (b) {
            // Right click keeps the fast path: pause without opening anything.
            if (b === Qt.RightButton && root.service)
                root.service.paused = !root.service.paused
            else
                root.toggle()
        }
    }

    KeyboardPanel {
        id: panel
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(Style.space(300))
        contentHeight: panel.fittedContentHeight(column.implicitHeight)

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: root.close()
            onTabRequested: function (direction) { root.switchPanel(direction) }

            Column {
                id: column
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: Style.space(12)

                Row {
                    spacing: Style.space(10)

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.glyph
                        color: root.bar ? root.bar.foreground : Color.foreground
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.displayLarge
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(2)

                        Text {
                            text: "OLED Guard"
                            color: root.bar ? root.bar.foreground : Color.foreground
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            font.bold: true
                        }

                        Text {
                            text: root.stateLine
                            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.5)
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                        }
                    }
                }

                PanelSeparator { width: parent.width }

                PanelSectionHeader { text: "PROTECTION" }

                ButtonGroup {
                    width: parent.width
                    value: root.modeValue
                    options: [
                        { value: "off", label: "Off", tooltip: "No attenuation at all" },
                        { value: "dim", label: "Dim", tooltip: "Flat attenuation across the bar strip" },
                        { value: "checker", label: "Checker", tooltip: "Rotating checkerboard. Not more protective than Dim, and textured" }
                    ]
                    onChanged: function (value) { root.setMode(value) }
                }

                PanelSectionHeader { text: "DEPTH" }

                ButtonGroup {
                    width: parent.width
                    enabled: root.guardEnabled
                    opacity: root.guardEnabled ? 1 : 0.4
                    value: root.depthValue
                    options: [
                        { value: "light", label: "Light", tooltip: "10% while working, 40% idle" },
                        { value: "medium", label: "Medium", tooltip: "15% while working, 55% idle" },
                        { value: "deep", label: "Deep", tooltip: "25% while working, 75% idle" }
                    ]
                    onChanged: function (value) { root.setDepth(value) }
                }

                PanelSeparator { width: parent.width }

                PanelSectionHeader { text: "BAR" }

                // The strongest mitigation for a static bar is not attenuating
                // it -- it is not drawing it. Omarchy already ships the toggle;
                // surfacing it here puts the two options side by side.
                Row {
                    width: parent.width
                    spacing: Style.space(8)

                    PanelActionButton {
                        anchors.verticalCenter: parent.verticalCenter
                        iconText: String.fromCodePoint(0xF06D1) // eye-off-outline
                        tooltipText: "Hide the bar entirely"
                        bordered: true
                        onClicked: root.toggleBarVisibility()
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Hide the bar"
                        color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.3)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                    }
                }

                PanelSeparator {
                    width: parent.width
                    visible: root.savedLine !== ""
                }

                Text {
                    width: parent.width
                    visible: root.savedLine !== ""
                    text: root.savedLine
                    wrapMode: Text.WordWrap
                    color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.6)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                }
            }
        }
    }
}
