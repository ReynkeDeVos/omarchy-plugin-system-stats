import QtQuick
import Quickshell
import "." as SystemStats

ShellRoot {
  id: testRoot

  property bool finished: false
  readonly property string caseName: String(Quickshell.env("SYSTEM_STATS_CASE"))
  readonly property string expectedStatus: String(Quickshell.env("SYSTEM_STATS_EXPECTED_STATUS"))
  readonly property int expectedPercent: Number(Quickshell.env("SYSTEM_STATS_EXPECTED_PERCENT"))
  readonly property string expectedError: String(Quickshell.env("SYSTEM_STATS_EXPECTED_ERROR"))

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

  function checkSnapshot(snapshot) {
    if (finished || snapshot.sequence !== 1) return
    if (!verify(snapshot.schemaVersion === 1, "schema version")) return
    if (!verify(Number.isSafeInteger(snapshot.generation), "safe generation")) return
    if (!verify(snapshot.generation > 4294967295, "wide generation")) return
    var expectedPhase = expectedStatus === "available" ? "live" : "degraded"
    if (!verify(snapshot.phase === expectedPhase, "snapshot phase")) return
    if (!verify(snapshot.cpu.status === expectedStatus, "CPU status")) return
    if (!verify(snapshot.ram.status === "unavailable" && snapshot.ram.since > 0, "stable RAM unavailability")) return
    if (!verify(snapshot.gpu.status === "unavailable" && snapshot.gpu.since === snapshot.ram.since, "stable GPU unavailability")) return
    if (expectedStatus === "available") {
      if (!verify(snapshot.cpu.value.percent === expectedPercent, caseName + " CPU percentage")) return
      if (!verify(snapshot.cpu.value.actualWindowMs > 0, caseName + " complete CPU window")) return
      if (!verify(snapshot.cpu.value.actualWindowMs === snapshot.cpu.window.actualMs, caseName + " window identity")) return
      if (!verify(snapshot.cpu.evidence === "fixtureTested", caseName + " evidence status")) return
    } else if (expectedError !== "") {
      if (!verify(snapshot.cpu.error.code === expectedError, caseName + " CPU error")) return
    }
    if (!verify(Object.isFrozen(snapshot), "snapshot immutability")) return
    if (!verify(Object.isFrozen(snapshot.cpu), "CPU metric immutability")) return
    if (snapshot.cpu.value && !verify(Object.isFrozen(snapshot.cpu.value), "CPU value immutability")) return

    finished = true
    console.log("TEST-GENERATION: " + snapshot.generation)
    console.log("TEST-PASS: " + caseName + " public session snapshot")
    Qt.quit()
  }

  SystemStats.Service {
    id: session
  }

  Connections {
    target: session
    function onCurrentChanged() { testRoot.checkSnapshot(session.current) }
  }

  Timer {
    interval: 2000
    running: true
    onTriggered: testRoot.fail("timed out waiting for snapshot")
  }

  Component.onCompleted: {
    if (!verify(session.current.phase === "initializing", "initial phase")) return
    if (!verify(session.current.sequence === 0, "initial sequence")) return
    if (!verify(session.current.cpu.since === 0, "initial CPU since")) return
    if (!verify(Object.isFrozen(session.current), "initial snapshot immutability")) return
  }
}
