import QtQuick
import Quickshell
import "plugin" as SystemStats

ShellRoot {
  id: testRoot

  property bool finished: false

  function fail(message) {
    if (finished) return
    finished = true
    console.error("TEST-FAIL: " + message)
    Qt.quit()
  }

  function verify(condition, message) {
    if (!condition) fail(message)
    return condition
  }

  function checkWidget(snapshot) {
    if (finished || snapshot.sequence !== 1) return
    if (!verify(snapshot.phase === "degraded", "GPU failure degrades the snapshot")) return
    if (!verify(widget.cpuVisible && widget.ramVisible,
                "GPU failure leaves CPU and RAM visible")) return
    if (!verify(!widget.gpuVisible, "unavailable GPU value is not shown as a percentage")) return
    if (!verify(widget.gpuUnavailable, "the GPU failure remains observable")) return
    if (!verify(widget.gpuDisplayValue === "", "the failed GPU publishes no bar value")) return
    if (!verify(!widget.gpuMetricVisible,
                "an unavailable GPU metric is fully hidden from the bar")) return
    if (!verify(!widget.warningVisible, "healthy host metrics avoid a global warning")) return
    if (!verify(widget.Accessible.name.indexOf("GPU") === -1,
                "the unavailable GPU is also omitted from the accessible bar name")) return
    if (!verify(widget.gpuStatusSummary()
                === "GPU counters are not readable with the current permissions.",
                "detail panel explains the permission failure")) return
    if (!verify(widget.gpuMeasurementPath() === "Intel DRM fdinfo",
                "detail panel names the failed measurement path")) return
    if (!verify(widget.gpuEvidenceSummary() === "Fixture-tested",
                "detail panel preserves the evidence status")) return
    widget.open()
    if (!verify(widget.opened, "detail panel opens for the GPU failure")) return
    finished = true
    console.log("TEST-PASS: Intel GPU error is detailed without cluttering the bar")
    Qt.quit()
  }

  SystemStats.Service {
    id: session
  }

  Connections {
    target: session
    function onCurrentChanged() { testRoot.checkWidget(session.current) }
  }

  FakeBar {
    id: fakeBar
    session: session
  }

  SystemStats.BarWidget {
    id: widget
    bar: fakeBar
  }

  Timer {
    interval: 2000
    running: true
    onTriggered: testRoot.fail("timed out waiting for the Intel GPU error")
  }
}
