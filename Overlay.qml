import QtQuick
import Quickshell
import Quickshell.Wayland

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
    property int phaseX: 0
    property int phaseY: 0
    property int fadeMs: 1500

    readonly property bool verticalEdge: edge === "left" || edge === "right"

    screen: modelData

    // Stay mapped until the fade has actually finished, otherwise dropping the
    // surface would cut the transition off at whatever alpha it had reached.
    visible: attenuation > 0 || veil.opacity > 0.001

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

    Item {
        id: veil
        anchors.fill: parent
        clip: true

        // Flat dim and checkerboard are the same average attenuation spent two
        // ways. The checker doubles the alpha but applies it to half the
        // pixels, trading contrast for deeper rest on the pixels it covers.
        opacity: overlay.checkerboard ? Math.min(1, overlay.attenuation * 2) : overlay.attenuation

        Behavior on opacity {
            NumberAnimation {
                duration: overlay.fadeMs
                easing.type: Easing.InOutQuad
            }
        }

        Rectangle {
            anchors.fill: parent
            visible: !overlay.checkerboard
            color: "black"
        }

        Image {
            visible: overlay.checkerboard
            source: Qt.resolvedUrl("checker.png")
            fillMode: Image.Tile

            // Offset by the current phase and oversize to match, so rotating
            // the pattern never uncovers an edge of the strip.
            x: -overlay.phaseX
            y: -overlay.phaseY
            width: parent.width + 2
            height: parent.height + 2

            smooth: false
            mipmap: false
            cache: true
        }
    }
}
