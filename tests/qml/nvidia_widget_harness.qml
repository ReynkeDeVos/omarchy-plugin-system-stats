import QtQuick
import Quickshell
import "." as SystemStats

ShellRoot {
  id: testRoot

  property bool finished: false

  function fail(message) {
    if (finished) return
    finished = true
    console.error("TEST-FAIL: Nvidia widget: " + message)
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
                "Nvidia success keeps every bar metric visible")) return
    if (!verify(widget.gpuDisplayValue === "47",
                "bar shows the UUID-selected Nvidia percentage")) return
    if (!verify(widget.selectedGpuStableId
                === "nvidia:GPU-22222222-2222-2222-2222-222222222222",
                "detail state names the UUID-selected Nvidia device")) return
    if (!verify(widget.gpuStatusSummary() === "47% graphics engine busy",
                "detail panel summarizes the Nvidia engine value")) return
    if (!verify(widget.gpuMeasurementPath() === "NVIDIA NVML graphics engine",
                "detail panel names the Nvidia measurement path")) return
    if (!verify(widget.gpuEvidenceSummary() === "Fixture-tested",
                "detail panel names the fixture evidence")) return
    if (!verify(widget.Accessible.name.indexOf("GPU 47 Prozent") !== -1,
                "Nvidia usage is included in the accessible bar name")) return
    widget.open()
    if (!verify(widget.opened, "detail panel opens for the Nvidia value")) return
    finished = true
    console.log("TEST-PASS: Nvidia GPU usage reaches bar and detail panel")
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
    onTriggered: testRoot.fail("timed out waiting for the Nvidia GPU value")
  }
}
