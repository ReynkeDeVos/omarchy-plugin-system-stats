import QtQuick
import Quickshell
import "." as SystemStats

ShellRoot {
  id: testRoot

  readonly property int logicalSecondMs: Number(Quickshell.env("SYSTEM_STATS_SECOND_MS"))
  property bool finished: false
  property string stage: "initializing-ten"
  property double stageStartedAtMs: 0
  property double lastSuccessfulAt: -1

  ElapsedTimer { id: elapsed }

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

  function configure(revision, interval) {
    stageStartedAtMs = elapsed.elapsedMs()
    session.configure({ configRevision: revision, intervalSeconds: interval })
  }

  function checkSnapshot(snapshot) {
    if (finished) return
    var elapsedInStage = elapsed.elapsedMs() - stageStartedAtMs

    if (stage === "initializing-ten") {
      if (snapshot.cpu.status === "unavailable" && snapshot.cpu.error.code === "stale") {
        if (!verify(elapsedInStage >= 3 * logicalSecondMs,
                    "initialization remains neutral before freshness limit")) return
        stage = "waiting-ten"
        return
      }
      return
    }

    if (stage === "waiting-ten") {
      if (snapshot.cpu.status !== "available") return
      if (!verify(snapshot.configRevision === 1, "ten-second result revision")) return
      if (!verify(snapshot.cpu.value.percent === 50, "ten-second result")) return
      stage = "waiting-five"
      configure(2, 5)
      return
    }

    if (stage === "waiting-five") {
      if (snapshot.configRevision !== 2 || snapshot.cpu.status !== "available") return
      if (!verify(snapshot.cpu.value.percent === 0, "zero remains available")) return
      lastSuccessfulAt = snapshot.cpu.sampledAtMs
      stage = "stale-five"
      stageStartedAtMs = elapsed.elapsedMs()
      return
    }

    if (stage === "stale-five") {
      if (snapshot.cpu.status !== "unavailable" || snapshot.cpu.error.code !== "stale") return
      if (!verify(elapsedInStage >= 3 * logicalSecondMs,
                  "five-second value is not stale early")) return
      if (!verify(snapshot.cpu.lastSuccessfulAt === lastSuccessfulAt,
                  "stale metric exposes last success")) return
      stage = "recover-five"
      return
    }

    if (stage === "recover-five") {
      if (snapshot.cpu.status !== "available") return
      if (!verify(snapshot.cpu.value.percent === 50, "sample after deliberate stale gap")) return
      stage = "waiting-two"
      configure(3, 2)
      return
    }

    if (stage === "waiting-two") {
      if (snapshot.configRevision !== 3 || snapshot.cpu.status !== "available") return
      if (!verify(snapshot.cpu.value.percent === 37, "two-second value before failure")) return
      lastSuccessfulAt = snapshot.cpu.sampledAtMs
      stage = "failed-two"
      stageStartedAtMs = elapsed.elapsedMs()
      return
    }

    if (stage === "failed-two") {
      if (snapshot.cpu.status !== "unavailable"
          || snapshot.cpu.error.code !== "missingRequiredField") return
      if (!verify(elapsedInStage < 4 * logicalSecondMs,
                  "failed expected sample becomes unavailable before stale limit")) return
      if (!verify(snapshot.cpu.lastSuccessfulAt === lastSuccessfulAt,
                  "sample failure exposes last success")) return
      finished = true
      console.log("TEST-PASS: initialization, stale gaps, zero, and sample failures stay distinct")
      Qt.quit()
    }
  }

  SystemStats.Service { id: session }

  Connections {
    target: session
    function onCurrentChanged() { testRoot.checkSnapshot(session.current) }
  }

  Timer {
    interval: 5000
    running: true
    onTriggered: testRoot.fail("timed out waiting for freshness behavior at " + stage)
  }

  Component.onCompleted: configure(1, 10)
}
