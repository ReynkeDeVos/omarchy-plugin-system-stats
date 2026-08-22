import QtQuick
import QtQuick.Window
import Quickshell
import "plugin" as SystemStats

ShellRoot {
  id: previewRoot

  readonly property string outputDirectory: String(Quickshell.env("SYSTEM_STATS_REVIEW_DIR"))
  property bool finished: false

  function fail(message) {
    if (finished) return
    finished = true
    console.error("TEST-FAIL: visual widget states: " + message)
    Qt.quit()
  }

  function verify(condition, message) {
    if (!condition) fail(message)
    return condition
  }

  function linearChannel(channel) {
    return channel <= 0.04045 ? channel / 12.92
      : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function luminance(color) {
    return 0.2126 * linearChannel(color.r)
      + 0.7152 * linearChannel(color.g)
      + 0.0722 * linearChannel(color.b)
  }

  function contrastRatio(foreground, background) {
    var lighter = Math.max(luminance(foreground), luminance(background))
    var darker = Math.min(luminance(foreground), luminance(background))
    return (lighter + 0.05) / (darker + 0.05)
  }

  function capture(item, path, size, callback) {
    item.grabToImage(function(result) {
      if (!result.saveToFile(outputDirectory + "/" + path)) {
        fail("could not save " + path)
        return
      }
      callback()
    }, size)
  }

  function availableMetric(value, path) {
    return {
      status: "available",
      value: value,
      sampledAtMs: 5000,
      window: { actualMs: 2000 },
      evidence: "fixtureTested",
      path: path
    }
  }

  function failedMetric(scope, path, diagnostic) {
    return {
      status: "unavailable",
      error: {
        code: scope === "gpu" ? "permissionDenied" : "sourceUnreadable",
        scope: scope,
        retryability: "retryable",
        pathId: path,
        diagnostic: diagnostic
      },
      since: 4000,
      lastSuccessfulAt: 3000,
      evidence: "fixtureTested"
    }
  }

  function partialSnapshot() {
    return {
      schemaVersion: 1,
      generation: 4,
      sequence: 7,
      configRevision: 0,
      phase: "degraded",
      publishedAtMs: 5000,
      cpu: availableMetric({ percent: 42, actualWindowMs: 2000 }, "proc-stat"),
      ram: availableMetric({
        percent: 63,
        usedBytes: 10 * 1073741824,
        totalBytes: 16 * 1073741824
      }, "proc-meminfo"),
      gpu: failedMetric("gpu", "intel-fdinfo", "Permission denied"),
      selection: {
        mode: "auto",
        status: "selected",
        stableId: "pci:0000:00:02.0"
      },
      source: { status: "running", lastSuccessfulAt: 5000 }
    }
  }

  function failedSnapshot() {
    return {
      schemaVersion: 1,
      generation: 4,
      sequence: 8,
      configRevision: 0,
      phase: "degraded",
      publishedAtMs: 5000,
      cpu: failedMetric("cpu", "proc-stat", "CPU source failed"),
      ram: failedMetric("ram", "proc-meminfo", "RAM source failed"),
      gpu: failedMetric("gpu", "intel-fdinfo", "GPU source failed"),
      selection: {
        mode: "auto",
        status: "selected",
        stableId: "pci:0000:00:02.0"
      },
      source: {
        status: "backoff",
        error: { code: "collectorExited", scope: "source" },
        lastSuccessfulAt: 3000,
        nextRestartAt: 7000
      }
    }
  }

  function captureStates() {
    var darkBackground = Qt.color("#10151d")
    var darkForeground = Qt.color("#dbe2ef")
    if (!verify(contrastRatio(darkForeground, darkBackground) >= 4.5,
                "dark theme text contrast is below 4.5:1")) return
    if (!verify(widget.cpuVisible && widget.ramVisible && !widget.gpuMetricVisible,
                "partial failure does not hide only the unavailable metric")) return
    if (!verify(widget.Accessible.name.indexOf("GPU") === -1,
                "hidden partial failures leak into the accessible bar name")) return

    capture(captureSurface, "system-stats-partial-dark.png", Qt.size(720, 144), function() {
      var lightBackground = Qt.color("#f3f4f6")
      var lightForeground = Qt.color("#18212f")
      fakeBar.barForeground = lightForeground
      fakeBar.foreground = lightForeground
      captureSurface.color = lightBackground
      barSurface.color = "#ffffff"
      fakeSession.current = failedSnapshot()
      Qt.callLater(function() {
        if (!verify(contrastRatio(lightForeground, lightBackground) >= 4.5,
                    "light theme text contrast is below 4.5:1")) return
        if (!verify(widget.warningVisible
                    && widget.Accessible.name.indexOf("No system metrics") !== -1,
                    "total failure lacks a textual and accessible warning")) return
        capture(captureSurface, "system-stats-failed-light.png", Qt.size(720, 144), function() {
          fakeBar.barForeground = darkForeground
          fakeBar.foreground = darkForeground
          fakeSession.current = partialSnapshot()
          widget.open()
          panelTimer.start()
        })
      })
    })
  }

  QtObject {
    id: fakeSession

    signal commandSettled(int commandId, bool accepted, string errorCode)

    property var current: previewRoot.partialSnapshot()
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

    function configure() { return 1 }
    function refreshGpuInventory() { return 1 }
  }

  FakeBar {
    id: fakeBar
    session: fakeSession
  }

  Window {
    id: previewWindow

    width: 360
    height: 72
    visible: true
    color: "transparent"

    Rectangle {
      id: captureSurface

      anchors.fill: parent
      color: "#10151d"

      Rectangle {
        id: barSurface

        anchors.centerIn: parent
        width: parent.width
        height: 26
        color: "#171d28"

        SystemStats.BarWidget {
          id: widget
          anchors.centerIn: parent
          bar: fakeBar
        }
      }
    }
  }

  Timer {
    id: panelTimer
    interval: 300
    onTriggered: {
      if (!verify(widget._detailPanel.contentWidth > widget.implicitWidth
                  && widget._detailPanel.contentHeight > fakeBar.barSize * 4
                  && (widget._detailPanel.availableCardHeight <= 0
                      || widget._detailPanel.contentHeight
                        <= widget._detailPanel.availableCardHeight
                          + widget._detailPanel.verticalContentInset),
                  "detail panel geometry no longer matches the prototype: "
                  + widget._detailPanel.contentWidth + "x"
                  + widget._detailPanel.contentHeight + " vs bar "
                  + widget.implicitWidth + "x" + fakeBar.barSize)) return
      finished = true
      console.log("TEST-PASS: degraded and failed states rendered; panel, theme, and contrast geometry checked")
      Qt.quit()
    }
  }

  Timer {
    id: stateTimer
    interval: 100
    onTriggered: previewRoot.captureStates()
  }

  Timer {
    interval: 3000
    running: true
    onTriggered: previewRoot.fail("timed out")
  }

  Component.onCompleted: stateTimer.start()
}
