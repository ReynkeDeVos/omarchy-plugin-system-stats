import QtQuick
import Quickshell
import "." as SystemStats

ShellRoot {
  id: testRoot

  readonly property string selectedId: "nvidia:GPU-22222222-2222-2222-2222-222222222222"
  readonly property string otherId: "pci:0000:03:00.0"
  property bool finished: false
  property int initialInventoryRevision: 0

  function fail(message) {
    if (finished) return
    finished = true
    console.error("TEST-FAIL: measurement-error-stability: " + message)
    Qt.quit()
  }

  function verify(condition, message) {
    if (!condition) fail(message)
    return condition
  }

  function hasDevice(stableId) {
    for (var i = 0; i < session.gpuInventory.devices.length; i++) {
      if (session.gpuInventory.devices[i].stableId === stableId) return true
    }
    return false
  }

  function verifySnapshot(snapshot) {
    return verify(snapshot.cpu.status === "available", "CPU remains available")
      && verify(snapshot.ram.status === "available", "RAM remains available")
      && verify(snapshot.gpu.status === "unavailable",
                "the identity mismatch remains unavailable")
      && verify(snapshot.gpu.value === undefined,
                "no mismatched GPU value is published")
      && verify(snapshot.gpu.error.code === "sourceUnreadable",
                "the identity mismatch stays a measurement error")
      && verify(snapshot.gpu.error.pathId === "nvidia-nvml",
                "the error names the selected measurement path")
      && verify(snapshot.gpu.error.diagnostic.indexOf("does not match") !== -1,
                "the detail diagnostic explains the identity mismatch")
      && verify(snapshot.gpu.evidence === "fixtureTested",
                "the error preserves its evidence status")
      && verify(snapshot.gpu.error.stableId === selectedId,
                "the error stays bound to the selected UUID")
      && verify(snapshot.selection.status === "selected",
                "a measurement error does not clear the selection")
      && verify(snapshot.selection.stableId === selectedId,
                "a measurement error does not select the other GPU")
  }

  function check(snapshot) {
    if (finished || snapshot.sequence < 1
        || session.gpuInventory.revision < 1) return
    if (!verifySnapshot(snapshot)) return

    if (snapshot.sequence === 1) {
      initialInventoryRevision = session.gpuInventory.revision
      if (!verify(hasDevice(otherId), "the fallback candidate is inventoried")) return
      return
    }

    if (snapshot.sequence >= 2) {
      if (!verify(session.gpuInventory.revision === initialInventoryRevision,
                  "measurement errors do not trigger inventory discovery")) return
      if (!verify(hasDevice(otherId), "the other GPU remains only a candidate")) return
      finished = true
      console.log("TEST-PASS: measurement errors do not cause GPU reselection")
      Qt.quit()
    }
  }

  SystemStats.Service { id: session }

  Connections {
    target: session
    function onCurrentChanged() { testRoot.check(session.current) }
    function onGpuInventoryChanged() { testRoot.check(session.current) }
  }

  Timer {
    interval: 3000
    running: true
    onTriggered: testRoot.fail("timed out waiting for repeated measurement errors")
  }
}
