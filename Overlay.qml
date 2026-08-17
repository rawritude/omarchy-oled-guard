import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "GuardModel.js" as GuardModel

// One attenuation surface per screen, pinned over the bar strip.
//
// It is deliberately a strip and not a fullscreen layer: the guard only has
// business over the pixels that never change, and a surface the size of the
// bar is a rounding error to composite where a fullscreen one is not.
PanelWindow {
    id: overlay

    required property var modelData

    property string edge: "top"
    property int thickness: 26
    property real attenuation: 0
    property bool checkerboard: false
    property bool suspendOnFullscreen: true
    property int hyprRevision: 0
    property int phaseX: 0
    property int phaseY: 0
    property int fadeMs: 1500
    property int revealMs: 140
    property bool hovered: false
    property bool revealOnHover: false

    // Which duration applies is decided from the same inputs that move the
    // target, not from the animation's own progress -- deriving it from the
    // painted opacity would re-evaluate mid-flight and risk restarting the
    // animation it is meant to be timing.
    //
    // Fullscreen counts as a reveal too: a film just started, and leaving a
    // veil across the top of it for a second and a half is the bug this whole
    // suspend exists to avoid.
    readonly property bool revealingFast: (revealOnHover && hovered) || screenFullscreen
    readonly property int transitionMs: revealingFast ? revealMs : fadeMs

    readonly property bool verticalEdge: edge === "left" || edge === "right"

    screen: modelData

    // Fullscreen is resolved here, against THIS overlay's monitor, rather than
    // once globally off the focused workspace. Focus and fullscreen live on
    // different screens all the time: a film playing on one monitor while the
    // other holds focus would otherwise keep this veil sitting on top of the
    // film -- and it sits on the overlay layer, so it would be visible.
    readonly property bool screenFullscreen: {
        hyprRevision // re-evaluate when the service says the payload moved
        if (!suspendOnFullscreen)
            return false
        try {
            // modelData, not overlay.screen: `screen` is a window property, and
            // reading it here closes a loop back through visible -> veilOpacity
            // -> this binding. modelData is the same screen, straight from
            // Variants, and depends on nothing downstream.
            var monitor = Hyprland.monitorFor(modelData)
            var ws = monitor ? monitor.activeWorkspace : null
            var raw = ws ? ws.lastIpcObject : null
            return raw ? !!(raw.hasfullscreen || raw.hasFullscreen) : false
        } catch (e) {
            return false
        }
    }

    property real checkerContrast: 0.25

    readonly property real effectiveAttenuation: screenFullscreen ? 0 : attenuation
    readonly property var layers: GuardModel.veilLayers(effectiveAttenuation, checkerboard, checkerContrast)

    // Stay mapped until the fade has actually finished, otherwise dropping the
    // surface would cut the transition off at whatever alpha it had reached.
    visible: layers.floor > 0 || layers.checker > 0
             || floorVeil.opacity > 0.001 || checkerVeil.opacity > 0.001

    color: "transparent"

    anchors {
        top: overlay.verticalEdge || overlay.edge === "top"
        bottom: overlay.verticalEdge || overlay.edge === "bottom"
        left: !overlay.verticalEdge || overlay.edge === "left"
        right: !overlay.verticalEdge || overlay.edge === "right"
    }

    implicitWidth: verticalEdge ? thickness : 0
    implicitHeight: verticalEdge ? 0 : thickness

    WlrLayershell.namespace: "oled-guard"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Purely visual: never reserve space, never take a click. An empty input
    // region is what keeps the bar underneath fully usable while veiled.
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}

    // Two stacked black veils rather than one. They composite multiplicatively,
    // which is exactly the model GuardModel.veilLayers solves against, so the
    // painted result and the banked figure come from one derivation and cannot
    // drift apart. No opacity on the parent: that would multiply both layers
    // again and break the arithmetic.
    Item {
        id: veil
        anchors.fill: parent
        clip: true

        // Flat floor over the whole strip. In flat-dim mode this is the entire
        // effect; in checker mode it carries whatever depth the checker does
        // not, which is what keeps peak drive off 100%.
        Rectangle {
            id: floorVeil
            anchors.fill: parent
            color: "black"
            opacity: overlay.layers.floor

            Behavior on opacity {
                NumberAnimation {
                    duration: overlay.transitionMs
                    easing.type: overlay.revealingFast ? Easing.OutCubic : Easing.InOutQuad
                }
            }
        }

        Image {
            id: checkerVeil
            source: Qt.resolvedUrl("checker.png")
            fillMode: Image.Tile
            opacity: overlay.layers.checker

            // Offset by the current phase and oversize to match, so rotating
            // the pattern never uncovers an edge of the strip.
            x: -overlay.phaseX
            y: -overlay.phaseY
            width: parent.width + 2
            height: parent.height + 2

            smooth: false
            mipmap: false
            cache: true

            Behavior on opacity {
                NumberAnimation {
                    duration: overlay.transitionMs
                    easing.type: overlay.revealingFast ? Easing.OutCubic : Easing.InOutQuad
                }
            }
        }
    }
}
