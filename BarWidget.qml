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
  readonly property bool ramVisible: !initializing && snapshot.ram.status === "available"
  readonly property bool gpuVisible: !initializing && snapshot.gpu.status === "available"
  readonly property string displayValue: cpuVisible ? String(snapshot.cpu.value.percent) : ""
  readonly property string ramDisplayFormat: String(setting("ramDisplayFormat", "percent")) === "gib"
    ? "gib" : "percent"
  readonly property string ramGiBValue: ramVisible
    ? formatGiB(snapshot.ram.value.usedBytes) + "/" + formatGiB(snapshot.ram.value.totalBytes)
    : ""
  readonly property string ramDisplayValue: !ramVisible ? ""
    : (ramDisplayFormat === "gib" ? ramGiBValue : String(snapshot.ram.value.percent))
  readonly property string ramDisplayUnit: ramDisplayFormat === "gib" ? " GiB" : "%"
  readonly property string gpuDisplayValue: gpuVisible ? String(snapshot.gpu.value.percent) : ""
  readonly property bool warningVisible: !initializing && !cpuVisible && !ramVisible && !gpuVisible
  readonly property color metricColor: bar ? bar.barForeground : Color.foreground
  readonly property bool opened: popupOpen
  readonly property var gpuInventory: session ? session.gpuInventory : ({ revision: 0, devices: [] })
  readonly property var gpuOptions: buildGpuOptions()
  readonly property string selectedGpuStableId: snapshot && snapshot.selection
    && snapshot.selection.stableId ? String(snapshot.selection.stableId) : ""
  readonly property var selectedGpuDevice: findGpuDevice(selectedGpuStableId)
  readonly property string selectedGpuValue: {
    var selection = persistedGpuSelection()
    return selection.mode === "fixed" ? selection.stableId : "auto"
  }
  property bool popupOpen: false
  property string settingsError: ""
  property int _nextSettingsRevision: 1

  function open() {
    if (popupOpen) return
    popupOpen = true
    if (session) session.refreshGpuInventory()
  }

  function close() { popupOpen = false }
  function toggle() { popupOpen ? close() : open() }

  function persistedGpuSelection() {
    var selection = setting("gpuSelection", { mode: "auto", configRevision: 0 })
    if (!selection || typeof selection !== "object")
      return { mode: "auto", configRevision: 0 }
    if (selection.mode === "fixed" && validStableGpuId(selection.stableId)) {
      return {
        mode: "fixed",
        stableId: selection.stableId,
        configRevision: Number(selection.configRevision) || 0
      }
    }
    return { mode: "auto", configRevision: Number(selection.configRevision) || 0 }
  }

  function validStableGpuId(stableId) {
    if (typeof stableId !== "string") return false
    return /^pci:[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$/.test(stableId)
      || /^nvidia:GPU-[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$/.test(stableId)
  }

  function configurePersistedSelection() {
    if (!session) return
    var selection = persistedGpuSelection()
    var revision = Number.isSafeInteger(selection.configRevision)
      && selection.configRevision >= 0 ? selection.configRevision : 0
    _nextSettingsRevision = Math.max(_nextSettingsRevision, revision + 1,
                                     Number(session.current.configRevision) + 1)
    if (revision === 0 && selection.mode === "auto"
        && Number(session.current.configRevision) === 0) return
    session.configure({
      configRevision: revision,
      intervalSeconds: configuredIntervalSeconds(),
      gpuSelection: selection.mode === "fixed"
        ? { mode: "fixed", stableId: selection.stableId }
        : { mode: "auto" }
    })
  }

  function configuredIntervalSeconds() {
    var interval = Number(setting("intervalSeconds", 2))
    return Number.isInteger(interval) && interval >= 2 && interval <= 10
      ? interval : 2
  }

  function buildGpuOptions() {
    var options = [{ value: "auto", label: "Auto" }]
    var devices = gpuInventory.devices || []
    for (var i = 0; i < devices.length; i++) {
      if (!devices[i].selectable) continue
      options.push({
        value: devices[i].stableId,
        label: gpuOptionLabel(devices[i]),
        device: devices[i]
      })
    }
    return options
  }

  function gpuOptionLabel(device) {
    return device.label + " · " + gpuVendorName(device)
      + " · " + gpuDisplayName(device) + " · " + device.stableId
  }

  function gpuVendorName(device) {
    return device.vendor === "amd" ? "AMD"
      : (device.vendor === "nvidia" ? "NVIDIA" : "Intel")
  }

  function gpuDisplayName(device) {
    return device.displayRelation === "yes" ? "display connected"
      : (device.displayRelation === "no" ? "display not connected" : "display unknown")
  }

  function findGpuDevice(stableId) {
    var devices = gpuInventory.devices || []
    for (var i = 0; i < devices.length; i++) {
      if (devices[i].stableId === stableId) return devices[i]
    }
    return null
  }

  function selectionSummary() {
    if (!snapshot || !snapshot.selection) return "Detecting GPU devices…"
    if (snapshot.selection.status === "required") return "Choose a GPU for this multi-GPU system."
    if (snapshot.selection.status === "missing")
      return "The fixed GPU is missing: " + snapshot.selection.stableId
    if (snapshot.selection.status === "none") return "No selectable GPU was detected."
    return selectedGpuDevice ? selectedGpuDevice.label : snapshot.selection.stableId
  }

  function gpuStatusSummary() {
    if (!snapshot || !snapshot.gpu) return "Waiting for the first GPU sample…"
    if (snapshot.gpu.status === "available")
      return snapshot.gpu.value.percent + "% graphics engine busy"
    var code = snapshot.gpu.error ? snapshot.gpu.error.code : ""
    if (code === "permissionDenied")
      return "GPU counters are not readable with the current permissions."
    if (code === "insufficientVisibility")
      return "Some processes are hidden, so a reliable system-wide value is unavailable."
    if (code === "unsupportedDevice" && snapshot.gpu.error
        && String(snapshot.gpu.error.pathId || "").indexOf("intel-") === 0)
      return "This Intel driver exposes an unknown measurement ABI."
    if (code === "deviceMissing")
      return "The selected GPU is no longer present."
    if (code === "counterReset")
      return "GPU counters reset; the next complete sample will retry."
    if (code === "noTrueEnginePath")
      return "No true graphics-engine measurement path is available."
    if (code === "stale")
      return "The last GPU sample is no longer current."
    if (code === "selectionRequired")
      return "Choose a GPU before usage can be measured."
    return snapshot.gpu.error && snapshot.gpu.error.diagnostic
      ? snapshot.gpu.error.diagnostic : "GPU usage is unavailable."
  }

  function gpuMeasurementPath() {
    if (!snapshot || !snapshot.gpu) return "Not selected"
    var rawPath = snapshot.gpu.status === "available"
      ? snapshot.gpu.path
      : (snapshot.gpu.error ? snapshot.gpu.error.pathId : "")
    var path = rawPath === undefined || rawPath === null ? "" : String(rawPath)
    if (path === "intel-i915-pmu") return "i915 PMU engine time"
    if (path === "intel-i915-fdinfo") return "i915 DRM fdinfo"
    if (path === "intel-xe-fdinfo") return "Xe DRM cycle counters"
    if (path === "intel-fdinfo") return "Intel DRM fdinfo"
    if (path === "gpu-selection") return "GPU selection"
    if (path === "gpu-inventory") return "GPU inventory"
    return path === "" ? "No measurement path" : path
  }

  function gpuEvidenceSummary() {
    if (!snapshot || !snapshot.gpu) return "Not measured"
    var evidence = snapshot.gpu.evidence
    return evidence === "hardwareConfirmed" ? "Hardware-confirmed"
      : (evidence === "fixtureTested" ? "Fixture-tested" : "Not measured")
  }

  function selectGpu(value) {
    if (!session) return
    value = String(value)
    if (value !== "auto") {
      var device = findGpuDevice(value)
      if (!device || !device.selectable) {
        settingsError = "That GPU is no longer available. Reopen the picker to refresh it."
        return
      }
    }
    if (value === selectedGpuValue) return
    var selection = value === "auto"
      ? { mode: "auto" }
      : { mode: "fixed", stableId: value }
    var revision = Math.max(_nextSettingsRevision,
                            Number(session.current.configRevision) + 1)
    _nextSettingsRevision = revision + 1
    var persisted = selection.mode === "fixed"
      ? { mode: "fixed", stableId: selection.stableId, configRevision: revision }
      : { mode: "auto", configRevision: revision }
    var registry = bar && bar.shell ? bar.shell.pluginRegistry : null
    if (!registry || typeof registry.setBarWidget !== "function") {
      settingsError = "Omarchy Settings is unavailable."
      return
    }
    var error = registry.setBarWidget(moduleName, "gpuSelection", persisted, {})
    if (error) {
      settingsError = "GPU selection could not be saved: " + error
      return
    }
    settingsError = ""
    session.configure({
      configRevision: revision,
      intervalSeconds: configuredIntervalSeconds(),
      gpuSelection: selection
    })
  }

  function formatGiB(bytes) {
    return (Number(bytes) / 1073741824).toFixed(1)
  }

  function accessibleDescription() {
    if (initializing) return "System Stats wird initialisiert"
    var metrics = []
    if (cpuVisible) metrics.push("CPU " + displayValue + " Prozent")
    if (ramVisible) {
      metrics.push(ramDisplayFormat === "gib"
        ? "RAM " + ramGiBValue + " GiB"
        : "RAM " + ramDisplayValue + " Prozent")
    }
    if (gpuVisible) metrics.push("GPU " + gpuDisplayValue + " Prozent")
    return metrics.length > 0
      ? "System Stats, " + metrics.join(", ")
      : "System Stats, Messwerte nicht verfügbar"
  }

  implicitWidth: content.implicitWidth + Style.space(10)
  implicitHeight: barSize

  Accessible.role: Accessible.Button
  Accessible.name: accessibleDescription()

  onSettingsChanged: Qt.callLater(configurePersistedSelection)

  onMetricColorChanged: {
    cpuIcon.requestPaint()
    ramIcon.requestPaint()
    gpuIcon.requestPaint()
  }

  Row {
    id: content

    anchors.centerIn: parent
    spacing: Style.space(4)

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

    Row {
      visible: root.ramVisible
      spacing: Style.space(2)

      Canvas {
        id: ramIcon

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
          context.strokeRect(2 * scale, 4.5 * scale, 12 * scale, 7 * scale)
          context.strokeRect(4 * scale, 6.5 * scale, 2 * scale, 3 * scale)
          context.strokeRect(7 * scale, 6.5 * scale, 2 * scale, 3 * scale)
          context.strokeRect(10 * scale, 6.5 * scale, 2 * scale, 3 * scale)

          var pins = [4, 7, 10, 12]
          for (var i = 0; i < pins.length; i++) {
            var point = pins[i] * scale
            context.beginPath()
            context.moveTo(point, 11.5 * scale)
            context.lineTo(point, 13.5 * scale)
            context.stroke()
          }
        }

        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onVisibleChanged: if (visible) requestPaint()
      }

      Item {
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(ramPercentMetrics.advanceWidth, ramGiBCapacityMetrics.advanceWidth)
        height: ramValueText.implicitHeight

        Text {
          id: ramValueText

          anchors.fill: parent
          text: root.ramDisplayValue + root.ramDisplayUnit
          color: root.metricColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.features: { "tnum": 1 }
          horizontalAlignment: Text.AlignLeft
          verticalAlignment: Text.AlignVCenter
          renderType: Text.NativeRendering
        }

        TextMetrics {
          id: ramPercentMetrics
          font: ramValueText.font
          text: "100%"
        }

        TextMetrics {
          id: ramGiBCapacityMetrics
          font: ramValueText.font
          text: root.ramVisible
            ? root.formatGiB(root.snapshot.ram.value.totalBytes)
              + "/" + root.formatGiB(root.snapshot.ram.value.totalBytes) + " GiB"
            : "0.0/0.0 GiB"
        }
      }
    }

    Row {
      visible: root.gpuVisible
      spacing: Style.space(2)

      Canvas {
        id: gpuIcon

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
          context.strokeRect(2 * scale, 4 * scale, 11 * scale, 8 * scale)
          context.strokeRect(4.5 * scale, 6 * scale, 4 * scale, 4 * scale)
          context.beginPath()
          context.moveTo(13 * scale, 6 * scale)
          context.lineTo(15 * scale, 6 * scale)
          context.moveTo(13 * scale, 9 * scale)
          context.lineTo(15 * scale, 9 * scale)
          context.moveTo(5 * scale, 12 * scale)
          context.lineTo(5 * scale, 14 * scale)
          context.moveTo(9 * scale, 12 * scale)
          context.lineTo(9 * scale, 14 * scale)
          context.stroke()
        }

        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onVisibleChanged: if (visible) requestPaint()
      }

      Item {
        anchors.verticalCenter: parent.verticalCenter
        width: gpuDigitMetrics.advanceWidth
        height: gpuValueText.implicitHeight

        Text {
          id: gpuValueText

          anchors.fill: parent
          text: root.gpuDisplayValue
          color: root.metricColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.features: { "tnum": 1 }
          horizontalAlignment: Text.AlignRight
          verticalAlignment: Text.AlignVCenter
          renderType: Text.NativeRendering
        }

        TextMetrics {
          id: gpuDigitMetrics
          font: gpuValueText.font
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

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton
    cursorShape: Qt.PointingHandCursor
    onClicked: root.toggle()
  }

  PopupCard {
    id: detailPanel

    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: detailPanel.fittedContentWidth(Style.space(460))
    contentHeight: detailPanel.fittedContentHeight(panelContent.implicitHeight)

    Column {
      id: panelContent

      anchors.fill: parent
      spacing: Style.space(10)

      Text {
        width: parent.width
        text: "GPU device"
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Text {
        width: parent.width
        text: root.selectionSummary()
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.Wrap
      }

      Text {
        width: parent.width
        text: "GPU usage"
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Text {
        width: parent.width
        text: root.gpuStatusSummary()
        color: root.snapshot && root.snapshot.gpu.status === "unavailable"
          ? Color.urgent : (root.bar ? root.bar.foreground : Color.foreground)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.Wrap
      }

      Text {
        width: parent.width
        text: "Measurement · " + root.gpuMeasurementPath()
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: "Evidence · " + root.gpuEvidenceSummary()
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        width: parent.width
        text: "Selection"
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      ListView {
        id: gpuPicker

        width: parent.width
        height: Math.min(contentHeight, Style.space(300))
        spacing: Style.space(4)
        model: root.gpuOptions
        clip: true
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds

        delegate: Button {
          id: optionButton

          required property var modelData
          readonly property var device: modelData.device || null

          width: gpuPicker.width
          height: device ? Style.space(64) : Style.space(42)
          selected: root.selectedGpuValue === String(modelData.value)
          bordered: true
          focusable: true
          foreground: root.bar ? root.bar.foreground : Color.foreground
          accent: Color.accent
          onClicked: root.selectGpu(modelData.value)

          Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.controlPaddingX
            anchors.rightMargin: Style.spacing.controlPaddingX
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: optionButton.device ? optionButton.device.label : "Auto"
              color: optionButton.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: optionButton.selected
              elide: Text.ElideRight
            }

            Text {
              visible: optionButton.device !== null
              width: parent.width
              text: optionButton.device
                ? root.gpuVendorName(optionButton.device) + " · "
                  + root.gpuDisplayName(optionButton.device)
                : ""
              color: optionButton.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: optionButton.device ? optionButton.device.stableId
                : "Keep the current device when it remains available"
              color: optionButton.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }
          }
        }
      }

      Text {
        visible: root.settingsError !== ""
        width: parent.width
        text: root.settingsError
        color: Color.urgent
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }
    }
  }

  Component.onCompleted: Qt.callLater(configurePersistedSelection)
}
