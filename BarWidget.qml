pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as QQC
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
  readonly property string ramDisplayFormat: String(_ramDisplayFormatOverride
    || setting("ramDisplayFormat", "percent")) === "gib"
    ? "gib" : "percent"
  readonly property string ramGiBValue: ramVisible
    ? formatGiB(snapshot.ram.value.usedBytes) + "/" + formatGiB(snapshot.ram.value.totalBytes)
    : ""
  readonly property string ramDisplayValue: !ramVisible ? ""
    : (ramDisplayFormat === "gib" ? ramGiBValue : String(snapshot.ram.value.percent))
  readonly property string ramDisplayUnit: ramDisplayFormat === "gib" ? " GiB" : "%"
  readonly property bool warningVisible: !initializing && !cpuVisible && !ramVisible && !gpuVisible
  readonly property bool gpuUnavailable: !initializing && !gpuVisible
  readonly property bool gpuMetricVisible: gpuVisible
  readonly property string gpuDisplayValue: gpuVisible ? String(snapshot.gpu.value.percent) : ""
  readonly property color metricColor: bar ? bar.barForeground : Color.foreground
  readonly property color gpuColor: metricColor
  readonly property real ramWidthReserve: ramVisible
    ? Math.max(0, ramGiBCapacityMetrics.advanceWidth - ramPercentMetrics.advanceWidth)
    : 0
  readonly property bool opened: popupOpen
  readonly property var _detailPanel: detailPanel
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
  property string _ramDisplayFormatOverride: ""
  property int _intervalSecondsOverride: 0
  property var _pendingGpuSelection: null
  property string _lastOfferedRuntimeSettings: ""
  property int _pendingSettingsCommandId: 0

  function open() {
    if (popupOpen) return
    popupOpen = true
    if (session) session.refreshGpuInventory()
  }

  function close() { popupOpen = false }
  function toggle() { popupOpen ? close() : open() }

  function handleButton(button) {
    if (button === Qt.RightButton) {
      if (bar && typeof bar.run === "function") bar.run("xdg-terminal-exec btop")
      return
    }
    if (button === Qt.LeftButton) toggle()
  }

  function storedGpuSelection() {
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

  function persistedGpuSelection() {
    return _pendingGpuSelection || storedGpuSelection()
  }

  function synchronizeSettingOverrides() {
    _ramDisplayFormatOverride = ""
    _intervalSecondsOverride = 0
    _pendingGpuSelection = null
    configurePersistedSelection()
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
    var interval = configuredIntervalSeconds()
    var runtimeKey = runtimeSettingsKey(revision, interval, selection)
    if (runtimeKey === _lastOfferedRuntimeSettings) return
    _lastOfferedRuntimeSettings = runtimeKey
    if (revision === 0 && selection.mode === "auto"
        && interval === 2
        && Number(session.current.configRevision) === 0) return
    _pendingSettingsCommandId = session.configure(
      runtimeConfiguration(revision, interval, selection))
  }

  function configuredIntervalSeconds() {
    var interval = _intervalSecondsOverride > 0
      ? _intervalSecondsOverride : Number(setting("intervalSeconds", 2))
    return Number.isInteger(interval) && interval >= 2 && interval <= 10
      ? interval : 2
  }

  function settingRegistry() {
    return bar && bar.shell ? bar.shell.pluginRegistry : null
  }

  function persistSetting(key, value, failureLabel) {
    var registry = settingRegistry()
    if (!registry || typeof registry.setBarWidget !== "function") {
      settingsError = "Omarchy Settings is unavailable."
      return false
    }
    var error = registry.setBarWidget(moduleName, key, value, {})
    if (error) {
      settingsError = failureLabel + ": " + error
      return false
    }
    settingsError = ""
    return true
  }

  function selectionAtRevision(selection, revision) {
    return selection.mode === "fixed"
      ? { mode: "fixed", stableId: selection.stableId, configRevision: revision }
      : { mode: "auto", configRevision: revision }
  }

  function runtimeConfiguration(revision, interval, selection) {
    return {
      configRevision: revision,
      intervalSeconds: interval,
      gpuSelection: selection.mode === "fixed"
        ? { mode: "fixed", stableId: selection.stableId }
        : { mode: "auto" }
    }
  }

  function runtimeSettingsKey(revision, interval, selection) {
    return JSON.stringify(runtimeConfiguration(revision, interval, selection))
  }

  function offerRuntimeConfiguration(revision, interval, selection) {
    _lastOfferedRuntimeSettings = runtimeSettingsKey(revision, interval, selection)
    if (session) {
      _pendingSettingsCommandId = session.configure(
        runtimeConfiguration(revision, interval, selection))
    }
  }

  function setRamDisplayFormat(value) {
    value = String(value)
    if (value !== "percent" && value !== "gib") {
      settingsError = "RAM display format must be percent or GiB."
      return
    }
    if (value === ramDisplayFormat) return
    if (!persistSetting("ramDisplayFormat", value,
                        "RAM display format could not be saved")) return
    _ramDisplayFormatOverride = value
  }

  function setIntervalSeconds(value) {
    value = Number(value)
    if (!Number.isInteger(value) || value < 2 || value > 10) {
      settingsError = "Sampling interval must be a whole number from 2 to 10 seconds."
      return
    }
    if (value === configuredIntervalSeconds()) return
    var selection = persistedGpuSelection()
    var revision = Math.max(_nextSettingsRevision,
                            Number(session ? session.current.configRevision : 0) + 1)
    _nextSettingsRevision = revision + 1
    var persistedSelection = selectionAtRevision(selection, revision)
    if (!persistSetting("gpuSelection", persistedSelection,
                        "Runtime settings could not be saved")) return
    if (!persistSetting("intervalSeconds", value,
                        "Sampling interval could not be saved")) return
    _pendingGpuSelection = persistedSelection
    _intervalSecondsOverride = value
    offerRuntimeConfiguration(revision, value, selection)
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
    return errorSummary(snapshot.gpu.error || ({}), "gpu", false)
  }

  function metricFor(scope) {
    return snapshot && snapshot[scope] ? snapshot[scope] : null
  }

  function metricStatusSummary(scope) {
    var metric = metricFor(scope)
    if (!metric || metric.status === "initializing") return "Initializing"
    return metric.status === "available" ? "Available" : "Unavailable"
  }

  function metricLastSuccessSummary(scope) {
    var metric = metricFor(scope)
    if (!metric) return "No successful sample"
    var sampledAt = metric.status === "available"
      ? metric.sampledAtMs : metric.lastSuccessfulAt
    return sampledAt === undefined || sampledAt === null
      ? "No successful sample" : relativeTimeSummary(sampledAt, false)
  }

  function metricErrorSummary(scope) {
    var metric = metricFor(scope)
    if (!metric || metric.status === "initializing") return "Waiting for the first sample"
    if (metric.status === "available") return "None"
    return errorSummary(metric.error || ({}), scope, true)
  }

  function errorSummary(error, scope, preferDiagnostic) {
    if (preferDiagnostic && error.diagnostic) return String(error.diagnostic)
    var code = String(error.code || "")
    var pathId = String(error.pathId || "")
    if (scope === "gpu" && code === "permissionDenied")
      return "GPU counters are not readable with the current permissions."
    if (scope === "gpu" && code === "insufficientVisibility")
      return "Some processes are hidden, so a reliable system-wide value is unavailable."
    if (scope === "gpu" && code === "unsupportedDevice"
        && pathId.indexOf("intel-") === 0)
      return "This Intel driver exposes an unknown measurement ABI."
    if (scope === "gpu" && code === "unsupportedDevice"
        && pathId.indexOf("amd-") === 0)
      return "This AMD device does not expose a supported measurement ABI."
    if (scope === "gpu" && code === "deviceSuspended")
      return "The selected GPU is runtime-suspended."
    if (scope === "gpu" && code === "deviceMissing")
      return "The selected GPU is no longer present."
    if (scope === "gpu" && code === "malformedCounter")
      return "The GPU counter returned an invalid value."
    if (scope === "gpu" && code === "sourceUnreadable")
      return "The GPU counter could not be read."
    if (scope === "gpu" && code === "counterReset")
      return "GPU counters reset; the next complete sample will retry."
    if (scope === "gpu" && code === "stale")
      return "The last GPU sample is no longer current."
    if (code === "permissionDenied") return "The metric source is not readable with the current permissions."
    if (code === "missingRequiredField") return "A required field is missing from the metric source."
    if (code === "malformedCounter") return "The metric source returned an invalid counter."
    if (code === "counterReset") return "The counters reset; the next complete sample will retry."
    if (code === "dependencyMissing") return "A required measurement dependency is missing."
    if (code === "unsupportedDevice") return "The selected device does not expose a supported measurement path."
    if (code === "noTrueEnginePath") return "No true graphics-engine measurement path is available."
    if (code === "insufficientVisibility") return "Process visibility is insufficient for a reliable system-wide value."
    if (code === "deviceSuspended") return "The selected device is runtime-suspended."
    if (code === "deviceMissing") return "The selected device is no longer present."
    if (code === "selectionRequired") return "Choose a GPU before usage can be measured."
    if (code === "sampleTimeout") return "The metric sample timed out."
    if (code === "sampleOverrun") return "The metric sample exceeded its observation window."
    if (code === "stale") return "The last sample is no longer current."
    if (code === "collectorExited") return "The metric collector exited."
    if (code === "collectorUnresponsive") return "The metric collector stopped responding."
    if (code === "protocolError") return "The collector returned an invalid message."
    if (code === "sourceUnreadable") return "The metric source could not be read."
    if (error.diagnostic) return String(error.diagnostic)
    return scope === "source" ? "The metric source is unavailable."
      : (scope === "gpu" ? "GPU usage is unavailable." : "The metric is unavailable.")
  }

  function metricValueSummary(scope) {
    var metric = metricFor(scope)
    if (!metric || metric.status === "initializing") return "Waiting for the first sample"
    if (metric.status !== "available") return metricErrorSummary(scope)
    if (scope === "ram" && ramDisplayFormat === "gib") return ramGiBValue + " GiB used"
    var percent = String(metric.value.percent) + "%"
    if (scope === "gpu") return percent + " graphics engine busy"
    return percent
  }

  function measurementPathName(rawPath) {
    var path = rawPath === undefined || rawPath === null ? "" : String(rawPath)
    if (path === "proc-stat") return "/proc/stat"
    if (path === "proc-meminfo") return "/proc/meminfo"
    if (path === "intel-i915-pmu") return "i915 PMU engine time"
    if (path === "intel-i915-fdinfo") return "i915 DRM fdinfo"
    if (path === "intel-xe-fdinfo") return "Xe DRM cycle counters"
    if (path === "intel-fdinfo") return "Intel DRM fdinfo"
    if (path === "amd-gpu-busy-percent") return "AMD gpu_busy_percent"
    if (path === "amd-fdinfo") return "AMD DRM fdinfo"
    if (path === "amd-measurement") return "AMD measurement"
    if (path === "nvidia-nvml") return "NVIDIA NVML graphics engine"
    if (path === "gpu-selection") return "GPU selection"
    if (path === "gpu-inventory") return "GPU inventory"
    return path === "" ? "No measurement path" : path
  }

  function metricMeasurementPath(scope) {
    var metric = metricFor(scope)
    if (!metric) return "No measurement path"
    var rawPath = metric.status === "available"
      ? metric.path : (metric.error ? metric.error.pathId : "")
    return measurementPathName(rawPath)
  }

  function relativeTimeSummary(timestamp, future) {
    if (!snapshot || !Number.isFinite(Number(timestamp))) return future ? "Not scheduled" : "Never"
    var deltaMs = future
      ? Number(timestamp) - Number(snapshot.publishedAtMs)
      : Number(snapshot.publishedAtMs) - Number(timestamp)
    var seconds = Math.max(0, Math.round(deltaMs / 1000))
    if (seconds === 0) return future ? "now" : "just now"
    return future
      ? "in " + seconds + " second" + (seconds === 1 ? "" : "s")
      : seconds + " second" + (seconds === 1 ? "" : "s") + " ago"
  }

  function sourceStatusSummary() {
    var source = snapshot && snapshot.source ? snapshot.source : null
    if (!source || source.status === "starting") return "Starting"
    if (source.status === "backoff") return "Restart scheduled"
    return source.status === "running" ? "Running" : "Unavailable"
  }

  function sourceLastSuccessSummary() {
    var source = snapshot && snapshot.source ? snapshot.source : null
    return !source || source.lastSuccessfulAt === undefined
      ? "No successful sample"
      : relativeTimeSummary(source.lastSuccessfulAt, false)
  }

  function sourceNextRestartSummary() {
    var source = snapshot && snapshot.source ? snapshot.source : null
    return !source || source.nextRestartAt === undefined
      ? "Not scheduled" : relativeTimeSummary(source.nextRestartAt, true)
  }

  function sourceErrorSummary() {
    var source = snapshot && snapshot.source ? snapshot.source : null
    if (!source || !source.error) return "None"
    return errorSummary(source.error, "source", false)
  }

  function gpuMeasurementPath() {
    if (!snapshot || !snapshot.gpu) return "Not selected"
    return metricMeasurementPath("gpu")
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
    var persisted = selectionAtRevision(selection, revision)
    if (!persistSetting("gpuSelection", persisted,
                        "GPU selection could not be saved")) return
    _pendingGpuSelection = persisted
    offerRuntimeConfiguration(revision, configuredIntervalSeconds(), selection)
  }

  function formatGiB(bytes) {
    return (Number(bytes) / 1073741824).toFixed(1)
  }

  function accessibleDescription() {
    if (initializing) return "System Stats is initializing"
    if (warningVisible) return "System Stats. No system metrics are available"
    var metrics = []
    if (cpuVisible) metrics.push("CPU " + displayValue + " percent")
    if (ramVisible) {
      metrics.push(ramDisplayFormat === "gib"
        ? "RAM " + ramGiBValue + " GiB"
        : "RAM " + ramDisplayValue + " percent")
    }
    if (gpuVisible) metrics.push("GPU " + gpuDisplayValue + " percent")
    return metrics.length > 0
      ? "System Stats, " + metrics.join(", ")
      : "System Stats. No system metrics are available"
  }

  implicitWidth: content.implicitWidth + ramWidthReserve + Style.space(10)
  implicitHeight: barSize

  Accessible.role: Accessible.Button
  Accessible.name: accessibleDescription()
  Accessible.description: "Left click to toggle details. Right click to open btop."
  activeFocusOnTab: true

  Keys.onReturnPressed: root.toggle()
  Keys.onEnterPressed: root.toggle()
  Keys.onSpacePressed: root.toggle()

  onSettingsChanged: Qt.callLater(synchronizeSettingOverrides)

  Connections {
    target: root.session
    function onCommandSettled(commandId, accepted, errorCode) {
      if (commandId !== root._pendingSettingsCommandId) return
      root._pendingSettingsCommandId = 0
      if (!accepted)
        root.settingsError = "Runtime settings were rejected: " + errorCode
    }
  }

  onMetricColorChanged: {
    cpuIcon.requestPaint()
    ramIcon.requestPaint()
  }

  onGpuColorChanged: gpuIcon.requestPaint()

  BorderSurface {
    anchors.fill: parent
    z: -1
    radius: Style.cornerRadius
    color: root.activeFocus
      ? Style.focusFillFor(root.metricColor, Color.accent)
      : (clickArea.containsMouse
          ? Style.hoverFillFor(root.metricColor, Color.accent)
          : (root.popupOpen
              ? Style.selectedFillFor(root.metricColor, Color.accent)
              : "transparent"))
    borderSpec: root.activeFocus
      ? Border.controlSpec("focus", root.metricColor, Color.accent)
      : Border.none()

    Behavior on color { ColorAnimation { duration: 120 } }
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
        width: root.ramDisplayFormat === "gib"
          ? ramGiBCapacityMetrics.advanceWidth : ramPercentMetrics.advanceWidth
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
      visible: root.gpuMetricVisible
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
          context.strokeStyle = root.gpuColor
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
          color: root.gpuColor
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
        visible: root.gpuVisible
        anchors.verticalCenter: parent.verticalCenter
        text: "%"
        color: root.gpuColor
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
    id: clickArea

    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    onClicked: function(mouse) {
      root.forceActiveFocus()
      root.handleButton(mouse.button)
    }
  }

  PopupCard {
    id: detailPanel

    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: detailPanel.fittedContentWidth(Style.space(420))
    contentHeight: detailPanel.fittedContentHeight(panelContent.implicitHeight,
                                                   Style.space(620))

    Flickable {
      id: panelScroll

      anchors.fill: parent
      contentWidth: width
      contentHeight: panelContent.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      QQC.ScrollBar.vertical: QQC.ScrollBar {
        policy: panelScroll.contentHeight > panelScroll.height
          ? QQC.ScrollBar.AsNeeded : QQC.ScrollBar.AlwaysOff
      }

      Column {
        id: panelContent

        width: parent.width
        spacing: Style.space(12)

        Column {
          width: parent.width
          spacing: Style.space(2)

          Text {
            width: parent.width
            text: "System Stats"
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            text: "Shared metric source · " + root.sourceStatusSummary()
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.bar ? root.bar.foreground : Color.foreground
        }

        PanelSectionHeader {
          text: "METRICS"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        MetricDetail {
          title: "CPU"
          metricKey: "cpu"
        }

        MetricDetail {
          title: "RAM"
          metricKey: "ram"
        }

        MetricDetail {
          title: "GPU"
          metricKey: "gpu"
        }

        PanelSeparator {
          width: parent.width
          foreground: root.bar ? root.bar.foreground : Color.foreground
        }

        PanelSectionHeader {
          text: "GPU DEVICE"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
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
          text: "Vendor · " + (root.selectedGpuDevice
            ? root.gpuVendorName(root.selectedGpuDevice) : "Not selected")
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: "Stable identity · " + (root.selectedGpuStableId || "Not selected")
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WrapAnywhere
        }

        Text {
          width: parent.width
          text: "Evidence · " + root.gpuEvidenceSummary()
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        PanelSeparator {
          width: parent.width
          foreground: root.bar ? root.bar.foreground : Color.foreground
        }

        PanelSectionHeader {
          text: "SOURCE"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        Text {
          width: parent.width
          text: "Status · " + root.sourceStatusSummary()
          color: root.snapshot && root.snapshot.source
            && root.snapshot.source.error ? Color.urgent
            : (root.bar ? root.bar.foreground : Color.foreground)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          wrapMode: Text.Wrap
        }

        Text {
          width: parent.width
          text: "Last success · " + root.sourceLastSuccessSummary()
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        Text {
          visible: root.snapshot && root.snapshot.source
            && root.snapshot.source.error !== undefined
          width: parent.width
          text: "Reason · " + root.sourceErrorSummary()
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        Text {
          visible: root.snapshot && root.snapshot.source
            && root.snapshot.source.nextRestartAt !== undefined
          width: parent.width
          text: "Next restart · " + root.sourceNextRestartSummary()
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        PanelSeparator {
          width: parent.width
          foreground: root.bar ? root.bar.foreground : Color.foreground
        }

        PanelSectionHeader {
          text: "SETTINGS"
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        Row {
          width: parent.width
          spacing: Style.space(10)

          Dropdown {
            width: (parent.width - parent.spacing) / 2
            label: "Sampling interval"
            value: String(root.configuredIntervalSeconds())
            options: [
              { value: "2", label: "2 seconds" },
              { value: "3", label: "3 seconds" },
              { value: "4", label: "4 seconds" },
              { value: "5", label: "5 seconds" },
              { value: "6", label: "6 seconds" },
              { value: "7", label: "7 seconds" },
              { value: "8", label: "8 seconds" },
              { value: "9", label: "9 seconds" },
              { value: "10", label: "10 seconds" }
            ]
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            Accessible.role: Accessible.ComboBox
            Accessible.name: "Sampling interval"
            onChanged: function(value) { root.setIntervalSeconds(Number(value)) }
          }

          Dropdown {
            width: (parent.width - parent.spacing) / 2
            label: "RAM display"
            value: root.ramDisplayFormat
            options: [
              { value: "percent", label: "Percent" },
              { value: "gib", label: "Used / total GiB" }
            ]
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            Accessible.role: Accessible.ComboBox
            Accessible.name: "RAM display format"
            onChanged: function(value) { root.setRamDisplayFormat(value) }
          }
        }

        Text {
          width: parent.width
          text: "GPU selection"
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        ListView {
          id: gpuPicker

          width: parent.width
          height: Math.min(contentHeight, Style.space(230))
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
            Accessible.role: Accessible.RadioButton
            Accessible.name: String(modelData.label)
            Accessible.checked: selected
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
                  : "Keep the selected device while it remains available"
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
          Accessible.role: Accessible.AlertMessage
          Accessible.name: root.settingsError
        }

        Item {
          width: parent.width
          height: Style.space(2)
        }
      }
    }
  }

  component MetricDetail: Column {
    id: metricDetail

    required property string title
    required property string metricKey
    readonly property bool unavailable: root.metricStatusSummary(metricKey) === "Unavailable"

    width: panelContent.width
    spacing: Style.space(3)

    Item {
      width: parent.width
      implicitHeight: Math.max(metricTitle.implicitHeight, metricStatus.implicitHeight)

      Text {
        id: metricTitle

        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: metricDetail.title
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Text {
        id: metricStatus

        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: root.metricStatusSummary(metricDetail.metricKey)
        color: metricDetail.unavailable ? Color.urgent
          : (root.bar ? root.bar.foreground : Color.foreground)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    Text {
      width: parent.width
      text: root.metricValueSummary(metricDetail.metricKey)
      color: root.bar ? root.bar.foreground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.Wrap
    }

    Text {
      width: parent.width
      text: "Last success · " + root.metricLastSuccessSummary(metricDetail.metricKey)
      color: root.bar ? root.bar.foreground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }

    Text {
      width: parent.width
      text: "Measurement · " + root.metricMeasurementPath(metricDetail.metricKey)
      color: root.bar ? root.bar.foreground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }

    Text {
      width: parent.width
      text: "Reason · " + root.metricErrorSummary(metricDetail.metricKey)
      color: root.bar ? root.bar.foreground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }
  }

  Component.onCompleted: Qt.callLater(configurePersistedSelection)
}
