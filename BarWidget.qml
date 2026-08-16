import QtQuick

// Status indicator for OLED Guard.
//
// Intentionally built on a plain Item rather than the shell's internal
// BarWidget base: the host injects `bar`, `moduleName` and `settings` into
// whatever it loads, and declaring those three here keeps the plugin off
// omarchy's private QML import path -- which is what lets it survive an
// omarchy update it was not built against.
Item {
    id: root

    property QtObject bar: null
    property string moduleName: ""
    property var settings: ({})

    readonly property bool vertical: bar && bar.vertical !== undefined ? bar.vertical : false
    readonly property color foreground: bar && bar.foreground !== undefined ? bar.foreground : "#ffffff"

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

    readonly property string glyph: guardPaused ? "○" : (guardActive ? "●" : "◐")

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

    implicitWidth: content.implicitWidth
    implicitHeight: content.implicitHeight

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
            font.pixelSize: 11
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.savedText !== "" && !root.vertical
            text: root.savedText
            color: root.foreground
            opacity: 0.75
            font.pixelSize: 11
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
