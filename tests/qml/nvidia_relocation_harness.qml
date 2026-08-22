import QtQuick
import Quickshell
import Quickshell.Io
import "." as SystemStats

ShellRoot {
  id: testRoot

  readonly property string inventoryPath: String(Quickshell.env("SYSTEM_STATS_GPU_INVENTORY_FILE"))
  readonly property string selectedId: "nvidia:GPU-22222222-2222-2222-2222-222222222222"
  property bool finished: false
  property int stage: 0
  property int refreshCommandId: 0
  property bool refreshAccepted: false

  FileView {
    id: inventoryFile
    path: testRoot.inventoryPath
    atomicWrites: true
    blockWrites: true
    printErrors: true
  }

  function fail(message) {
    if (finished) return
    finished = true
    console.error("TEST-FAIL: Nvidia relocation: " + message)
    Qt.quit()
  }

  function verify(condition, message) {
    if (!condition) fail(message)
    return condition
  }

  function selectedDevice() {
    for (var i = 0; i < session.gpuInventory.devices.length; i++) {
      if (session.gpuInventory.devices[i].stableId === selectedId)
        return session.gpuInventory.devices[i]
    }
    return null
  }

  function checkSnapshot(snapshot) {
    if (finished) return
    if (stage === 0 && snapshot.sequence === 1
        && snapshot.gpu.status === "available") {
      if (!verify(snapshot.selection.stableId === selectedId,
                  "the UUID is initially selected")) return
      if (!verify(snapshot.gpu.value.device.pciBdf === "0000:01:00.0",
                  "the initial value uses the discovered PCI address")) return
      stage = 1
      inventoryFile.setText("" +
        "nvidia:GPU-11111111-1111-1111-1111-111111111111\tNVIDIA RTX Other Fixture\tnvidia\t0000:03:00.0\tno\t1\n" +
        selectedId + "\tNVIDIA GeForce RTX Fixture\tnvidia\t0000:02:00.0\tyes\t1\n")
      refreshCommandId = session.refreshGpuInventory()
      return
    }

    if (stage === 1 && refreshAccepted && snapshot.sequence >= 2
        && snapshot.gpu.status === "available") {
      var device = selectedDevice()
      if (!verify(device !== null && device.pciBdf === "0000:02:00.0",
                  "the refreshed inventory moves the UUID to its new PCI address")) return
      if (!verify(snapshot.selection.stableId === selectedId,
                  "the stable UUID remains selected")) return
      if (!verify(snapshot.gpu.value.device.stableId === selectedId,
                  "the sample remains bound to the stable UUID")) return
      if (!verify(snapshot.gpu.value.device.pciBdf === "0000:02:00.0",
                  "the sampler rebinds to the refreshed PCI identity")) return
      if (!verify(snapshot.gpu.value.percent === 47,
                  "the rebound device provides its own utilization value")) return
      finished = true
      console.log("TEST-PASS: Nvidia UUID rebinds after its PCI address changes")
      Qt.quit()
    }
  }

  SystemStats.Service { id: session }

  Connections {
    target: session
    function onCurrentChanged() { testRoot.checkSnapshot(session.current) }
    function onGpuInventoryChanged() { testRoot.checkSnapshot(session.current) }
    function onCommandSettled(commandId, accepted, errorCode) {
      if (commandId !== refreshCommandId) return
      refreshAccepted = accepted && errorCode === ""
      testRoot.checkSnapshot(session.current)
    }
  }

  Timer {
    interval: 3000
    running: true
    onTriggered: testRoot.fail("timed out waiting for the rebound sample")
  }
}
