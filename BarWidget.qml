import QtQuick
import qs.Ui
import qs.Commons

BarWidget {
  id: root

  moduleName: "reynkedevos.system-stats"

  readonly property var session: bar?.shell?.serviceFor(moduleName) ?? null
  readonly property var snapshot: session ? session.current : null
  readonly property int snapshotSequence: snapshot ? snapshot.sequence : 0
  readonly property bool initializing: !snapshot || snapshot.phase === "initializing"
  readonly property bool cpuVisible: !initializing && snapshot.cpu.status === "available"
  readonly property bool ramVisible: false
  readonly property bool gpuVisible: false
  readonly property string displayValue: cpuVisible ? String(snapshot.cpu.value.percent) : ""
  readonly property bool warningVisible: !initializing && !cpuVisible
  readonly property color metricColor: bar ? bar.barForeground : Color.foreground

  implicitWidth: content.implicitWidth + Style.space(10)
  implicitHeight: barSize

  Accessible.role: Accessible.StaticText
  Accessible.name: initializing
    ? "System Stats wird initialisiert"
    : (cpuVisible
        ? "System Stats, CPU " + displayValue + " Prozent"
        : "System Stats, Messwert nicht verfügbar")

  onMetricColorChanged: cpuIcon.requestPaint()

  Row {
    id: content

    anchors.centerIn: parent
    spacing: 0

    Text {
      visible: root.initializing
      text: "…"
      color: root.metricColor
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      renderType: Text.NativeRendering
    }

    Row {
      visible: root.cpuVisible
      spacing: Style.space(2)

      Canvas {
        id: cpuIcon

        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(12)
        height: width

        onPaint: {
          var context = getContext("2d")
          var scale = width / 16
          context.reset()
          context.strokeStyle = root.metricColor
          context.lineWidth = Math.max(1, 1.45 * scale)
          context.lineCap = "round"
          context.lineJoin = "round"
          context.strokeRect(4 * scale, 4 * scale, 8 * scale, 8 * scale)
          context.strokeRect(6.5 * scale, 6.5 * scale, 3 * scale, 3 * scale)

          var pins = [5, 8, 11]
          for (var i = 0; i < pins.length; i++) {
            var point = pins[i] * scale
            context.beginPath()
            context.moveTo(2 * scale, point)
            context.lineTo(4 * scale, point)
            context.moveTo(12 * scale, point)
            context.lineTo(14 * scale, point)
            context.moveTo(point, 2 * scale)
            context.lineTo(point, 4 * scale)
            context.moveTo(point, 12 * scale)
            context.lineTo(point, 14 * scale)
            context.stroke()
          }
        }

        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onVisibleChanged: if (visible) requestPaint()
      }

      Item {
        anchors.verticalCenter: parent.verticalCenter
        width: digitMetrics.advanceWidth
        height: valueText.implicitHeight

        Text {
          id: valueText

          anchors.fill: parent
          text: root.displayValue
          color: root.metricColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.features: { "tnum": 1 }
          horizontalAlignment: Text.AlignRight
          verticalAlignment: Text.AlignVCenter
          renderType: Text.NativeRendering
        }

        TextMetrics {
          id: digitMetrics
          font: valueText.font
          text: "100"
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "%"
        color: root.metricColor
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering
      }
    }

    Text {
      visible: root.warningVisible
      text: "!"
      color: root.metricColor
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
      renderType: Text.NativeRendering
    }
  }
}
