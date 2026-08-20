import QtQuick
import Quickshell
import "." as SystemStats

ShellRoot {
  id: testRoot

  readonly property int logicalSecondMs: Number(Quickshell.env("SYSTEM_STATS_SECOND_MS"))
  property bool finished: false
  property int nextInterval: 2
  property int expectedRevision: 0
  property double generation: 0
  property double initializedAtMs: 0
  property int acceptedCommands: 0
  property int rejectedCommands: 0
  property bool checkingLastValidConfiguration: false

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

  function requestNextInterval() {
    expectedRevision++
    var commandId = session.configure({
      configRevision: expectedRevision,
      intervalSeconds: nextInterval
    })
    verify(commandId > 0, "configuration command id")
  }

  function checkSnapshot(snapshot) {
    if (finished || snapshot.generation <= 0) return
    if (generation === 0) generation = snapshot.generation
    if (!verify(snapshot.generation === generation, "configuration does not restart helper")) return

    if (checkingLastValidConfiguration) {
      if (snapshot.cpu.status !== "available") return
      if (!verify(snapshot.configRevision === 9, "invalid configuration keeps revision 9")) return
      if (!verify(snapshot.cpu.value.actualWindowMs >= 8 * logicalSecondMs,
                  "invalid configuration keeps ten-second schedule")) return
      if (!verify(acceptedCommands === 9, "all supported intervals accepted")) return
      if (!verify(rejectedCommands === 3, "all invalid intervals rejected")) return
      finished = true
      console.log("TEST-PASS: interval configuration uses complete live windows")
      Qt.quit()
      return
    }

    if (snapshot.configRevision !== expectedRevision) return
    if (snapshot.cpu.status === "initializing") {
      initializedAtMs = elapsed.elapsedMs()
      return
    }
    if (snapshot.cpu.status !== "available") return
    if (!verify(snapshot.cpu.value.percent === 50, "configured CPU value")) return
    var elapsedWindowMs = elapsed.elapsedMs() - initializedAtMs
    if (!verify(elapsedWindowMs >= nextInterval * logicalSecondMs * 0.75,
                "configured value waits for a complete window")) return
    if (!verify(snapshot.cpu.value.actualWindowMs >= nextInterval * logicalSecondMs * 0.75,
                "helper reports the complete configured window")) return

    if (nextInterval < 10) {
      nextInterval++
      requestNextInterval()
      return
    }

    checkingLastValidConfiguration = true
    session.configure({ configRevision: 10, intervalSeconds: 1 })
    session.configure({ configRevision: 10, intervalSeconds: 11 })
    session.configure({ configRevision: 10, intervalSeconds: 2.5 })
  }

  SystemStats.Service { id: session }

  Connections {
    target: session

    function onCurrentChanged() { testRoot.checkSnapshot(session.current) }
    function onCommandSettled(commandId, accepted, errorCode) {
      if (accepted) {
        acceptedCommands++
      } else {
        if (!verify(errorCode === "invalidConfiguration", "configuration rejection reason")) return
        rejectedCommands++
      }
    }
  }

  Timer {
    interval: 5000
    running: true
    onTriggered: testRoot.fail("timed out waiting for live configuration")
  }

  Component.onCompleted: requestNextInterval()
}
