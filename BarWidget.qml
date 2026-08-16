import QtQuick

// Status indicator for OLED Guard.
//
// Intentionally built on a plain Item rather than the shell's internal
// BarWidget/WidgetButton bases: the host injects `bar`, `moduleName` and
// `settings` into whatever it loads, and everything else those bases provide
// (bar-height sizing, the tooltip handshake) is a few lines to do directly.
// Keeping the plugin off omarchy's private `qs.*` import path is what lets it
// survive an omarchy release it was not built against.
Item {
    id: root

    property QtObject bar: null
    property string moduleName: ""
    property var settings: ({})

    readonly property bool vertical: bar && bar.vertical !== undefined ? bar.vertical : false
    readonly property color foreground: bar && bar.foreground !== undefined ? bar.foreground : "#ffffff"

    // The bar lays its modules out in a plain Row and takes each slot's height
    // straight from the widget's implicitHeight. Sizing to the glyph would park
    // it against the top edge while every neighbour sits centred, so claim the
    // full bar thickness and centre the glyph inside it.
    readonly property int barSize: bar && bar.barSize > 0 ? bar.barSize : 26

    function setting(name, fallback) {
        var value = settings ? settings[name] : undefined
        return value === undefined || value === null ? fallback : value
    }

    // Show the reclaimed-time figure next to the glyph. Off by default: the
    // point of this plugin is to stop lighting pixels, so it should not insist
    // on lighting more of them to say so.
    readonly property bool showSaved: !!setting("showSaved", false)

    readonly property var service: {
        try {
            if (bar && bar.shell && typeof bar.shell.serviceFor === "function")
                return bar.shell.serviceFor("oled.guard")
        } catch (e) {
            return null
        }
        return null
    }

    readonly property bool guardActive: service ? !!service.active : false
    readonly property bool guardPaused: service ? !!service.paused : false
    readonly property bool guardFullscreen: service ? !!service.fullscreen : false
    readonly property real guardAttenuation: service ? Number(service.attenuation) || 0 : 0

    // Nerd Font (Material Design) shields, to sit alongside the first-party
    // indicators rather than as a lone Unicode dot among them. Spelled as
    // codepoints rather than literals: these live in plane 15, and any editor
    // or patch careless about astral characters silently truncates them to a
    // 4-digit codepoint plus a stray ASCII byte.
    readonly property string glyphGuarding: String.fromCodePoint(0xF0780) // shield-half-full
    readonly property string glyphStandby: String.fromCodePoint(0xF099D)  // shield-outline
    readonly property string glyphOff: String.fromCodePoint(0xF099E)      // shield-off-outline

    readonly property string glyph: {
        if (!service || guardPaused)
            return glyphOff
        if (guardActive)
            return glyphGuarding
        return glyphStandby
    }

    readonly property string tooltipMessage: {
        if (!service)
            return "OLED Guard: service not running"
        if (guardPaused)
            return "OLED Guard paused — click to resume"
        if (guardActive)
            return "OLED Guard dimming the bar " + Math.round(guardAttenuation * 100) + "% — click to pause"
        if (guardFullscreen)
            return "OLED Guard standing by — fullscreen content"
        return "OLED Guard standing by — click to pause"
    }

    // Read by the bar's tooltip plumbing (Bar.targetTooltipHovered) to confirm
    // the pointer is still on this widget before it commits to showing.
    property bool tooltipHovered: false

    readonly property string savedText: {
        if (!showSaved || !service || !service.stats)
            return ""
        try {
            var hours = service.stats.savedSeconds / 3600
            if (hours < 1)
                return ""
            return (hours < 10 ? (Math.round(hours * 10) / 10) : Math.round(hours)) + "h"
        } catch (e) {
            return ""
        }
    }

    implicitWidth: vertical ? barSize : content.implicitWidth + 10
    implicitHeight: vertical ? content.implicitHeight + 10 : barSize

    Row {
        id: content
        anchors.centerIn: parent
        spacing: root.savedText === "" ? 0 : 4

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.glyph
            color: root.foreground
            // Paused reads as "off", so it should look off rather than merely
            // differently shaped.
            opacity: root.guardPaused ? 0.45 : 1
            font.pixelSize: Math.round(root.barSize * 0.5)
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.savedText !== "" && !root.vertical
            text: root.savedText
            color: root.foreground
            opacity: 0.75
            font.pixelSize: Math.round(root.barSize * 0.42)
        }
    }

    HoverHandler {
        id: hover
        onHoveredChanged: {
            root.tooltipHovered = hovered
            if (!root.bar)
                return
            if (hovered) {
                if (typeof root.bar.showTooltip === "function")
                    root.bar.showTooltip(root, root.tooltipMessage)
            } else if (typeof root.bar.hideTooltip === "function") {
                root.bar.hideTooltip(root)
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        onClicked: {
            if (root.service)
                root.service.paused = !root.service.paused
        }
    }
}
