import QtQuick
import Quickshell
import "plugin" as SystemStats

ShellRoot {
  id: testRoot

  readonly property double gib: 1073741824
  property bool finished: false
  property var percentageWidths: []
  property real reservedWidth: 0

  function fail(message) {
    if (finished) return
    finished = true
    console.error("TEST-FAIL: widget contract: " + message)
    Qt.quit()
  }

  function verify(condition, message) {
    if (!condition) fail(message)
    return condition
  }

  function availableSnapshot(percent, usedGiB) {
    return {
      schemaVersion: 1,
      generation: 7,
      sequence: 11,
      configRevision: 0,
      phase: "live",
      publishedAtMs: 5000,
      cpu: {
        status: "available",
        value: { percent: percent, actualWindowMs: 2000 },
        sampledAtMs: 5000,
        window: { actualMs: 2000 },
        evidence: "fixtureTested",
        path: "proc-stat"
      },
      ram: {
        status: "available",
        value: {
          percent: percent,
          usedBytes: usedGiB * gib,
          totalBytes: 16 * gib
        },
        sampledAtMs: 5000,
        window: { actualMs: 2000 },
        evidence: "fixtureTested",
        path: "proc-meminfo"
      },
      gpu: {
        status: "available",
        value: {
          percent: percent,
          device: { stableId: "pci:0000:00:02.0" },
          semantics: "graphicsEngineBusy"
        },
        sampledAtMs: 5000,
        window: { actualMs: 2000 },
        evidence: "fixtureTested",
        path: "intel-i915-fdinfo"
      },
      selection: {
        mode: "auto",
        status: "selected",
        stableId: "pci:0000:00:02.0"
      },
      source: { status: "running" }
    }
  }

  function failedMetric(scope, path) {
    return {
      status: "unavailable",
      error: {
        code: "sourceUnreadable",
        scope: scope,
        retryability: "retryable",
        pathId: path,
        diagnostic: "fixture source failed"
      },
      since: 4000,
      lastSuccessfulAt: 3000,
      evidence: "fixtureTested"
    }
  }

  function failedSnapshot() {
    return {
      schemaVersion: 1,
      generation: 7,
      sequence: 12,
      configRevision: 0,
      phase: "degraded",
      publishedAtMs: 5000,
      cpu: failedMetric("cpu", "proc-stat"),
      ram: failedMetric("ram", "proc-meminfo"),
      gpu: failedMetric("gpu", "intel-i915-fdinfo"),
      selection: {
        mode: "auto",
        status: "selected",
        stableId: "pci:0000:00:02.0"
      },
      source: {
        status: "backoff",
        error: {
          code: "collectorExited",
          scope: "source",
          retryability: "retryable"
        },
        failureAt: 4000,
        lastSuccessfulAt: 3000,
        nextRestartAt: 7000
      }
    }
  }

  function checkWidth(value, next) {
    fakeSession.current = availableSnapshot(value, value === 100 ? 16 : 10)
    Qt.callLater(function() {
      percentageWidths.push(widget.implicitWidth)
      next()
    })
  }

  function checkStablePercentages() {
    checkWidth(9, function() {
      checkWidth(10, function() {
        checkWidth(99, function() {
          checkWidth(100, checkAvailableContract)
        })
      })
    })
  }

  function checkAvailableContract() {
    for (var i = 1; i < percentageWidths.length; i++) {
      if (!verify(percentageWidths[i] === percentageWidths[0],
                  "9, 10, 99, and 100 percent keep one width")) return
    }
    reservedWidth = widget.implicitWidth
    fakeSession.current = availableSnapshot(0, 0)
    Qt.callLater(function() {
      if (!verify(widget.cpuVisible && widget.ramVisible && widget.gpuVisible,
                  "all available zero-percent metrics stay visible")) return
      if (!verify(widget.displayValue === "0" && widget.ramDisplayValue === "0"
                  && widget.gpuDisplayValue === "0",
                  "zero percent is not treated as an error")) return
      if (!verify(widget.implicitWidth === reservedWidth,
                  "zero percent keeps the reserved width")) return
      if (!verify(widget.metricStatusSummary("cpu") === "Available",
                  "CPU status is available in the detail model")) return
      if (!verify(widget.metricMeasurementPath("cpu") === "/proc/stat",
                  "CPU detail names its measurement path")) return
      if (!verify(widget.metricErrorSummary("cpu") === "None",
                  "available metrics expose an explicit empty error field")) return
      checkRamFormat()
    })
  }

  function checkRamFormat() {
    var sequence = fakeSession.current.sequence
    widget.setRamDisplayFormat("gib")
    Qt.callLater(function() {
      if (!verify(widget.ramDisplayFormat === "gib", "RAM format control applies GiB")) return
      if (!verify(fakeBar.persistedSettings.ramDisplayFormat === "gib",
                  "RAM format control persists through Omarchy settings")) return
      if (!verify(fakeSession.current.sequence === sequence
                  && fakeSession.configureCount === 0,
                  "RAM format changes without sampling or collector configuration")) return
      if (!verify(widget.implicitWidth === reservedWidth,
                  "percent-to-GiB switch keeps the reserved width")) return
      fakeSession.current = availableSnapshot(100, 16)
      Qt.callLater(function() {
        if (!verify(widget.ramDisplayValue === "16.0/16.0",
                    "GiB control uses the current shared snapshot")) return
        if (!verify(widget.implicitWidth === reservedWidth,
                    "the complete GiB range keeps one width")) return
        checkInterval()
      })
    })
  }

  function checkInterval() {
    var sequence = fakeSession.current.sequence
    widget.setIntervalSeconds(5)
    if (!verify(fakeBar.persistedSettings.intervalSeconds === 5,
                "interval control persists through Omarchy settings")) return
    if (!verify(fakeSession.configureCount === 1
                && fakeSession.lastConfiguration.intervalSeconds === 5,
                "interval control configures the shared session once")) return
    if (!verify(fakeSession.current.sequence === sequence,
                "interval control does not manufacture a sample")) return
    checkInteractions()
  }

  function checkInteractions() {
    var snapshot = fakeSession.current
    fakeBar.runResult = false
    widget.handleButton(Qt.RightButton)
    if (!verify(fakeBar.runCount === 1
                && fakeBar.lastCommand === "xdg-terminal-exec btop",
                "right click launches only btop in a terminal")) return
    if (!verify(!widget.opened && fakeSession.current === snapshot,
                "the btop action changes neither panel nor metrics")) return
    widget.handleButton(Qt.LeftButton)
    var panel = widget._detailPanel
    if (!verify(widget.opened && fakeSession.refreshCount === 1,
                "left click opens the panel and refreshes the picker once")) return
    if (!verify(panel && panel.open && panel.contentWidth > widget.implicitWidth
                && panel.contentHeight > fakeBar.barSize * 4
                && (panel.availableCardHeight <= 0
                    || panel.contentHeight <= panel.availableCardHeight
                      + panel.verticalContentInset),
                "the open detail panel retains usable prototype geometry")) return
    widget.handleButton(Qt.LeftButton)
    if (!verify(!widget.opened, "a second left click closes the panel")) return
    checkFailureContract()
  }

  function checkFailureContract() {
    fakeSession.current = failedSnapshot()
    Qt.callLater(function() {
      if (!verify(widget.warningVisible, "total failure shows the compact warning")) return
      if (!verify(!widget.cpuVisible && !widget.ramVisible && !widget.gpuMetricVisible,
                  "total failure publishes no false bar values")) return
      if (!verify(widget.Accessible.name.indexOf("No system metrics are available") !== -1,
                  "the warning has a non-color accessible name")) return
      if (!verify(widget.metricStatusSummary("ram") === "Unavailable",
                  "RAM failure remains visible in details")) return
      if (!verify(widget.metricLastSuccessSummary("ram") === "2 seconds ago",
                  "details expose the last successful RAM sample")) return
      if (!verify(widget.metricMeasurementPath("ram") === "/proc/meminfo",
                  "RAM failure names its measurement path")) return
      if (!verify(widget.metricErrorSummary("ram") === "fixture source failed",
                  "RAM failure exposes its reason")) return
      if (!verify(widget.sourceStatusSummary() === "Restart scheduled",
                  "details expose source backoff")) return
      if (!verify(widget.sourceLastSuccessSummary() === "2 seconds ago",
                  "details expose the source's last success")) return
      if (!verify(widget.sourceNextRestartSummary() === "in 2 seconds",
                  "details expose the next restart")) return
      finished = true
      console.log("TEST-PASS: approved widget contract remains stable and operable")
      Qt.quit()
    })
  }

  QtObject {
    id: fakeSession

    signal commandSettled(int commandId, bool accepted, string errorCode)

    property var current: ({
      schemaVersion: 1,
      generation: 0,
      sequence: 0,
      configRevision: 0,
      phase: "initializing",
      publishedAtMs: 0,
      cpu: { status: "initializing", since: 0 },
      ram: { status: "initializing", since: 0 },
      gpu: { status: "initializing", since: 0 },
      selection: { mode: "auto", status: "none" },
      source: { status: "starting" }
    })
    property var gpuInventory: ({
      revision: 1,
      devices: [{
        stableId: "pci:0000:00:02.0",
        pciBdf: "0000:00:02.0",
        label: "Intel Graphics",
        vendor: "intel",
        displayRelation: "yes",
        selectable: true
      }]
    })
    property int configureCount: 0
    property int refreshCount: 0
    property var lastConfiguration: null

    function configure(settings) {
      configureCount++
      lastConfiguration = settings
      return configureCount
    }

    function refreshGpuInventory() {
      refreshCount++
      return refreshCount
    }
  }

  FakeBar {
    id: fakeBar
    session: fakeSession
  }

  SystemStats.BarWidget {
    id: widget
    bar: fakeBar
  }

  Timer {
    interval: 3000
    running: true
    onTriggered: testRoot.fail("timed out")
  }

  Component.onCompleted: {
    if (!verify(widget.initializing, "the neutral initialization state is visible")) return
    if (!verify(widget.Accessible.name.indexOf("initializing") !== -1,
                "initialization has an accessible name")) return
    checkStablePercentages()
  }
}
