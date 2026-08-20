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

  function localPath(url) {
    return decodeURIComponent(String(url).replace(/^file:\/\//, ""))
  }

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
    if (!verify(snapshot.generation === 1, "generation")) return
    var expectedPhase = expectedStatus === "available" ? "live" : "degraded"
    if (!verify(snapshot.phase === expectedPhase, "snapshot phase")) return
    if (!verify(snapshot.cpu.status === expectedStatus, "CPU status")) return
    if (expectedStatus === "available") {
      if (!verify(snapshot.cpu.value.percent === expectedPercent, caseName + " CPU percentage")) return
    } else if (expectedError !== "") {
      if (!verify(snapshot.cpu.error === expectedError, caseName + " CPU error")) return
    }
    if (!verify(Object.isFrozen(snapshot), "snapshot immutability")) return
    if (!verify(Object.isFrozen(snapshot.cpu), "CPU metric immutability")) return
    if (!verify(Object.isFrozen(snapshot.cpu.value), "CPU value immutability")) return

    finished = true
    console.log("TEST-PASS: " + caseName + " public session snapshot")
    Qt.quit()
  }

  SystemStats.Service {
    id: session

    autoStart: false
    helperCommand: [
      testRoot.localPath(Qt.resolvedUrl("bin/system-stats-helper")),
      "--frames",
      testRoot.localPath(Qt.resolvedUrl("fixtures/cpu/" + testRoot.caseName + ".stat")),
      "--interval-ms",
      "1"
    ]

    onSnapshotPublished: function(snapshot) { testRoot.checkSnapshot(snapshot) }
  }

  Timer {
    interval: 2000
    running: true
    onTriggered: testRoot.fail("timed out waiting for snapshot")
  }

  Component.onCompleted: {
    if (!verify(session.current.phase === "initializing", "initial phase")) return
    if (!verify(session.current.sequence === 0, "initial sequence")) return
    if (!verify(Object.isFrozen(session.current), "initial snapshot immutability")) return
    session.start()
  }
}
