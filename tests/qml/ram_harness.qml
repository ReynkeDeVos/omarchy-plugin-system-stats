import QtQuick
import Quickshell
import "." as SystemStats

ShellRoot {
  id: testRoot

  readonly property string caseName: String(Quickshell.env("SYSTEM_STATS_CASE"))
  readonly property string expectedCpuStatus: String(Quickshell.env("SYSTEM_STATS_EXPECTED_CPU_STATUS"))
  readonly property int expectedCpuPercent: Number(Quickshell.env("SYSTEM_STATS_EXPECTED_CPU_PERCENT"))
  readonly property string expectedRamStatus: String(Quickshell.env("SYSTEM_STATS_EXPECTED_RAM_STATUS"))
  readonly property int expectedRamPercent: Number(Quickshell.env("SYSTEM_STATS_EXPECTED_RAM_PERCENT"))
  readonly property double expectedUsedBytes: Number(Quickshell.env("SYSTEM_STATS_EXPECTED_USED_BYTES"))
  readonly property double expectedTotalBytes: Number(Quickshell.env("SYSTEM_STATS_EXPECTED_TOTAL_BYTES"))
  readonly property string expectedRamError: String(Quickshell.env("SYSTEM_STATS_EXPECTED_RAM_ERROR"))
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

  function checkSnapshot(snapshot) {
    if (finished || snapshot.sequence !== 1) return

    var expectedPhase = expectedCpuStatus === "available"
      && expectedRamStatus === "available" ? "live" : "degraded"
    if (!verify(snapshot.phase === expectedPhase, caseName + " snapshot phase")) return
    if (!verify(snapshot.cpu.status === expectedCpuStatus, caseName + " CPU status")) return
    if (expectedCpuStatus === "available"
        && !verify(snapshot.cpu.value.percent === expectedCpuPercent,
                   caseName + " isolated CPU value")) return

    if (!verify(snapshot.ram.status === expectedRamStatus, caseName + " RAM status")) return
    if (expectedRamStatus === "available") {
      if (!verify(snapshot.ram.value.percent === expectedRamPercent,
                  caseName + " RAM percentage")) return
      if (!verify(snapshot.ram.value.usedBytes === expectedUsedBytes,
                  caseName + " used bytes")) return
      if (!verify(snapshot.ram.value.totalBytes === expectedTotalBytes,
                  caseName + " total bytes")) return
      if (!verify(snapshot.ram.sampledAtMs === snapshot.publishedAtMs,
                  caseName + " shared observation timestamp")) return
      if (!verify(snapshot.ram.window
                  && snapshot.ram.window.actualMs > 0,
                  caseName + " RAM observation window")) return
      if (expectedCpuStatus === "available"
          && !verify(snapshot.ram.sampledAtMs === snapshot.cpu.sampledAtMs,
                     caseName + " atomic CPU and RAM timestamp")) return
      if (expectedCpuStatus === "available"
          && !verify(snapshot.ram.window.actualMs === snapshot.cpu.window.actualMs,
                     caseName + " shared CPU and RAM window")) return
      if (!verify(snapshot.ram.evidence === "fixtureTested", caseName + " RAM evidence")) return
      if (!verify(snapshot.ram.path === "proc-meminfo", caseName + " RAM path")) return
      if (!verify(Object.isFrozen(snapshot.ram.value), caseName + " RAM value immutability")) return
    } else {
      if (!verify(snapshot.ram.error.code === expectedRamError,
                  caseName + " RAM error")) return
      if (!verify(snapshot.ram.value === undefined, caseName + " no RAM fallback value")) return
    }

    if (!verify(Object.isFrozen(snapshot), caseName + " snapshot immutability")) return
    if (!verify(Object.isFrozen(snapshot.ram), caseName + " RAM metric immutability")) return

    finished = true
    console.log("TEST-PASS: " + caseName + " RAM through public session snapshot")
    Qt.quit()
  }

  SystemStats.Service { id: session }

  Connections {
    target: session
    function onCurrentChanged() { testRoot.checkSnapshot(session.current) }
  }

  Timer {
    interval: 2000
    running: true
    onTriggered: testRoot.fail("timed out waiting for " + caseName)
  }

  Component.onCompleted: {
    if (!verify(session.current.ram.status === "initializing", "initial RAM status")) return
    if (!verify(session.current.ram.since === 0, "initial RAM timestamp")) return
  }
}
