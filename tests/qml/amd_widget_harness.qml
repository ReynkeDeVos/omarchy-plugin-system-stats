import QtQuick
import Quickshell
import "." as SystemStats

ShellRoot {
  id: testRoot

  property bool finished: false

  function fail(message) {
    if (finished) return
    finished = true
    console.error("TEST-FAIL: AMD widget: " + message)
    Qt.quit()
  }

  function verify(condition, message) {
    if (!condition) fail(message)
    return condition
  }

  function checkWidget(snapshot) {
    if (finished || snapshot.sequence !== 1) return
    if (!verify(widget.session === session, "widget reads the shared session")) return
    if (!verify(widget.cpuVisible && widget.ramVisible && widget.gpuVisible,
                "AMD success keeps every bar metric visible")) return
    if (!verify(widget.gpuDisplayValue === "73", "bar shows the selected AMD percentage")) return
    if (!verify(widget.selectedGpuStableId === "pci:0000:c4:00.0",
                "detail state names the selected AMD device")) return
    if (!verify(widget.gpuStatusSummary() === "73% graphics engine busy",
                "detail panel summarizes the AMD engine value")) return
    if (!verify(widget.gpuMeasurementPath() === "AMD gpu_busy_percent",
                "detail panel names the AMD measurement path")) return
    if (!verify(widget.gpuEvidenceSummary() === "Fixture-tested",
                "detail panel names the fixture evidence")) return
    if (!verify(widget.Accessible.name.indexOf("GPU 73 Prozent") !== -1,
                "AMD usage is included in the accessible bar name")) return
    widget.open()
    if (!verify(widget.opened, "detail panel opens for the AMD value")) return
    finished = true
    console.log("TEST-PASS: AMD GPU usage reaches bar and detail panel")
    Qt.quit()
  }

  SystemStats.Service { id: session }

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
    interval: 3000
    running: true
    onTriggered: testRoot.fail("timed out waiting for the AMD GPU value")
  }
}
