import QtQuick
import Quickshell
import "plugin" as SystemStats

ShellRoot {
  id: testRoot

  property bool reloadResetChecked: false

  readonly property var savedConfig: ({
    bar: {
      layout: {
        left: [],
        center: [],
        right: [{
          id: "reynkedevos.system-stats",
          intervalSeconds: 3,
          ramDisplayFormat: "gib",
          gpuSelection: { mode: "auto", configRevision: 4 }
        }]
      }
    }
  })

  function verify(condition, message) {
    if (condition) return true
    console.error("TEST-FAIL: " + message)
    Qt.quit()
    return false
  }

  function checkRestoredSettings() {
    var expectedSelection = JSON.stringify({ mode: "auto", configRevision: 4 })
    if (!verify(screenA.configuredIntervalSeconds() === 3,
                "screen A restores the saved interval after reload")) return
    if (!verify(screenB.configuredIntervalSeconds() === 3,
                "screen B restores the saved interval after reload")) return
    if (!verify(screenA.ramDisplayFormat === "gib",
                "screen A restores the saved RAM format after reload")) return
    if (!verify(screenB.ramDisplayFormat === "gib",
                "screen B restores the saved RAM format after reload")) return
    if (!verify(JSON.stringify(screenA.storedGpuSelection()) === expectedSelection,
                "screen A restores the saved GPU selection after reload")) return
    if (!verify(JSON.stringify(screenB.storedGpuSelection()) === expectedSelection,
                "screen B restores the saved GPU selection after reload")) return
    if (!reloadResetChecked) {
      reloadResetChecked = true
      screenA.settings = ({})
      screenB.settings = ({})
      Qt.callLater(checkRestoredSettings)
      return
    }
    console.log("TEST-PASS: recreated widgets restore Quattro inline settings")
    Qt.quit()
  }

  QtObject {
    id: fakeSession

    signal commandSettled(int commandId, bool accepted, string errorCode)

    readonly property var current: ({
      generation: 1,
      sequence: 7,
      phase: "initializing",
      configRevision: 0,
      source: {}
    })
    readonly property var gpuInventory: ({ revision: 0, devices: [] })

    function configure() { return 1 }
    function refreshGpuInventory() {}
  }

  FakeBar {
    id: fakeBarA
    session: fakeSession
  }

  FakeBar {
    id: fakeBarB
    session: fakeSession
  }

  SystemStats.BarWidget {
    id: screenA
    bar: fakeBarA
    settings: ({})
  }

  SystemStats.BarWidget {
    id: screenB
    bar: fakeBarB
    settings: ({})
  }

  Timer {
    interval: 0
    running: true
    onTriggered: {
      fakeBarA.persistedShellConfig = testRoot.savedConfig
      fakeBarB.persistedShellConfig = testRoot.savedConfig
      Qt.callLater(testRoot.checkRestoredSettings)
    }
  }
}
