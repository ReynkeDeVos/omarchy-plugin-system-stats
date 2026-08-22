import QtQuick
import Quickshell
import "plugin" as SystemStats

ShellRoot {
  id: testRoot

  readonly property string fixedGpuId: "nvidia:GPU-22222222-2222-2222-2222-222222222222"
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

  function check(snapshot) {
    if (finished || snapshot.configRevision !== 7
        || snapshot.selection.status !== "selected") return
    if (!verify(snapshot.selection.mode === "fixed", "restored fixed mode")) return
    if (!verify(snapshot.selection.stableId === fixedGpuId,
                "restored stable identity ignores enumeration order")) return
    if (!verify(widget.session === session, "restored setting reaches public session")) return
    if (!verify(fakeBar.persistenceCount === 0, "restoring does not rewrite settings")) return
    finished = true
    console.log("TEST-PASS: persisted fixed GPU is restored in a new session")
    Qt.quit()
  }

  SystemStats.Service { id: session }

  FakeBar {
    id: fakeBar
    session: session
  }

  SystemStats.BarWidget {
    id: widget
    bar: fakeBar
    settings: ({
      ramDisplayFormat: "percent",
      gpuSelection: {
        mode: "fixed",
        stableId: testRoot.fixedGpuId,
        configRevision: 7
      }
    })
  }

  Connections {
    target: session
    function onCurrentChanged() { testRoot.check(session.current) }
  }

  Timer {
    interval: 3000
    running: true
    onTriggered: testRoot.fail("timed out waiting for restored selection")
  }
}
