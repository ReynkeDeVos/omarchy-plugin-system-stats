import QtQuick
import Quickshell
import "." as SystemStats

ShellRoot {
  id: testRoot

  readonly property string caseName: String(Quickshell.env("SYSTEM_STATS_GPU_CASE"))
  readonly property string expectedMode: String(Quickshell.env("SYSTEM_STATS_GPU_SELECTION_MODE") || "auto")
  readonly property string expectedStatus: String(Quickshell.env("SYSTEM_STATS_GPU_EXPECTED_STATUS"))
  readonly property string expectedStableId: String(Quickshell.env("SYSTEM_STATS_GPU_EXPECTED_ID"))
  readonly property string expectedVendor: String(Quickshell.env("SYSTEM_STATS_GPU_EXPECTED_VENDOR"))
  readonly property string expectedDisplay: String(Quickshell.env("SYSTEM_STATS_GPU_EXPECTED_DISPLAY"))
  readonly property int expectedDeviceCount: Number(Quickshell.env("SYSTEM_STATS_GPU_EXPECTED_COUNT"))
  property bool finished: false
  property bool configureRequested: false
  property int configureCommandId: 0

  function fail(message) {
    if (finished) return
    finished = true
    console.error("TEST-FAIL: " + caseName + ": " + message)
    Qt.quit()
  }

  function verify(condition, message) {
    if (!condition) fail(message)
    return condition
  }

  function selectedDevice() {
    for (var i = 0; i < session.gpuInventory.devices.length; i++) {
      if (session.gpuInventory.devices[i].stableId === expectedStableId)
        return session.gpuInventory.devices[i]
    }
    return null
  }

  function check(snapshot) {
    if (finished || snapshot.sequence < 1
        || session.gpuInventory.revision < 1) return
    if (expectedMode === "fixed" && snapshot.selection.mode !== "fixed") {
      if (!configureRequested) {
        configureRequested = true
        configureCommandId = session.configure({
          configRevision: 1,
          intervalSeconds: 2,
          gpuSelection: { mode: "fixed", stableId: expectedStableId }
        })
      }
      return
    }
    if (expectedMode === "auto") {
      if (!verify(snapshot.cpu.status === "available", "CPU remains available")) return
      if (!verify(snapshot.ram.status === "available", "RAM remains available")) return
    }
    if (!verify(snapshot.gpu.status === "unavailable",
                "missing fixture measurement stays explicit")) return
    if (!verify(session.gpuInventory.devices.length === expectedDeviceCount,
                "the complete fixture inventory is published")) return
    if (!verify(snapshot.selection.mode === expectedMode,
                "the requested selection mode is active")) return
    if (!verify(snapshot.selection.status === expectedStatus,
                "the mode applies the expected selection status")) return

    if (expectedStatus === "selected") {
      if (!verify(snapshot.selection.stableId === expectedStableId,
                  "the mode selects the expected stable identity")) return
      var device = selectedDevice()
      if (!verify(device !== null, "the selected identity is inventoried")) return
      if (!verify(device.vendor === expectedVendor,
                  "the selected device keeps its vendor")) return
      if (!verify(device.displayRelation === expectedDisplay,
                  "the selected device keeps its display relation")) return
      if (!verify(snapshot.gpu.error.stableId === expectedStableId,
                  "the metric error remains bound to the selected identity")) return
    } else {
      if (!verify(snapshot.selection.stableId === undefined,
                  "ambiguous display GPUs do not fall back to the first device")) return
      if (!verify(snapshot.gpu.error.code === "selectionRequired",
                  "ambiguous display GPUs require an explicit selection")) return
    }

    finished = true
    console.log("TEST-PASS: " + caseName + " follows the shared "
                + expectedMode + " rules")
    Qt.quit()
  }

  SystemStats.Service { id: session }

  Connections {
    target: session
    function onCurrentChanged() { testRoot.check(session.current) }
    function onGpuInventoryChanged() { testRoot.check(session.current) }
    function onCommandSettled(commandId, accepted, errorCode) {
      if (commandId !== configureCommandId) return
      if (!accepted) testRoot.fail("fixed configuration rejected: " + errorCode)
      else testRoot.check(session.current)
    }
  }

  Timer {
    interval: 3000
    running: true
    onTriggered: testRoot.fail("timed out waiting for the selection matrix")
  }
}
