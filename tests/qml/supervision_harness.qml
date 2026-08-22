import QtQuick
import Quickshell
import "." as SystemStats

ShellRoot {
  id: testRoot

  readonly property string scenario: String(Quickshell.env("SYSTEM_STATS_SCENARIO"))
  readonly property int logicalSecondMs: Number(Quickshell.env("SYSTEM_STATS_SECOND_MS"))
  property bool finished: false
  property var backoffs: []
  property double lastRestartAt: -1
  property bool sawUnresponsive: false
  property double firstSuccess: -1

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

  function checkBackoff(snapshot) {
    if (snapshot.source.status === "backoff"
        && snapshot.source.nextRestartAt !== lastRestartAt) {
      lastRestartAt = snapshot.source.nextRestartAt
      backoffs.push(Math.round((snapshot.source.nextRestartAt
                                - snapshot.source.failureAt) / logicalSecondMs))
    }
    if (backoffs.length < 8) return
    var expected = [1, 2, 4, 8, 16, 30, 30, 1]
    for (var i = 0; i < expected.length; i++) {
      if (!verify(backoffs[i] === expected[i], "backoff step " + i)) return
    }
    if (snapshot.source.status === "backoff") {
      if (!verify(snapshot.source.error.code === "collectorExited",
                  "crash reason is shared during backoff")) return
      if (!verify(snapshot.source.lastSuccessfulAt > 0,
                  "source exposes last success during backoff")) return
      if (!verify(snapshot.source.nextRestartAt > snapshot.source.failureAt,
                  "source exposes next restart during backoff")) return
      return
    }
    if (snapshot.source.status !== "running" || snapshot.cpu.status !== "available") return
    if (!verify(snapshot.cpu.lastSuccessfulAt === undefined,
                "available value is not decorated as a failure")) return
    finished = true
    console.log("TEST-PASS: crash backoff resets after stable operation")
    Qt.quit()
  }

  function checkUnresponsive(snapshot) {
    if (snapshot.cpu.status === "available" && snapshot.cpu.value.percent === 37) {
      firstSuccess = snapshot.cpu.sampledAtMs
    }
    if (snapshot.cpu.status === "unavailable"
        && snapshot.cpu.error.code === "collectorUnresponsive") {
      if (!verify(snapshot.cpu.lastSuccessfulAt === firstSuccess,
                  "unresponsive source retains last success")) return
      sawUnresponsive = true
    }
    if (!sawUnresponsive
        || snapshot.source.status !== "running"
        || snapshot.cpu.status !== "available"
        || snapshot.cpu.value.percent !== 55) return
    finished = true
    console.log("TEST-PASS: unresponsive helper exits before its replacement")
    Qt.quit()
  }

  function checkSnapshot(snapshot) {
    if (finished) return
    if (scenario === "backoff-reset") checkBackoff(snapshot)
    else checkUnresponsive(snapshot)
  }

  SystemStats.Service { id: session }

  Connections {
    target: session
    function onCurrentChanged() { testRoot.checkSnapshot(session.current) }
  }

  Timer {
    interval: 7000
    running: true
    onTriggered: testRoot.fail("timed out waiting for " + scenario)
  }
}
