import QtQuick
import Quickshell
import "." as SystemStats

ShellRoot {
  id: testRoot

  property bool finished: false
  property bool sawProtocolError: false
  property int lastAcceptedSequence: 0

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
    if (finished) return
    if (snapshot.source.error && snapshot.source.error.code === "protocolError") {
      sawProtocolError = true
    }
    if (snapshot.sequence === lastAcceptedSequence) return
    lastAcceptedSequence = snapshot.sequence
    if (snapshot.sequence === 1) {
      if (!verify(snapshot.cpu.status === "unavailable"
                  && snapshot.cpu.error.code === "stale",
                  "already-old sample is unavailable on receipt")) return
      return
    }
    if (snapshot.sequence === 2) {
      if (!verify(snapshot.cpu.status === "available"
                  && snapshot.cpu.value.percent === 37,
                  "fresh protocol value recovers availability")) return
      return
    }
    if (!verify(snapshot.sequence === 3, "invalid sequences were discarded")) return
    if (!verify(snapshot.cpu.status === "available"
                && snapshot.cpu.value.percent === 42,
                "invalid percentages were discarded")) return
    if (!verify(sawProtocolError, "protocol diagnostics are published")) return
    finished = true
    console.log("TEST-PASS: invalid protocol traffic is discarded")
    Qt.quit()
  }

  SystemStats.Service { id: session }

  Connections {
    target: session
    function onCurrentChanged() { testRoot.checkSnapshot(session.current) }
  }

  Timer {
    interval: 3000
    running: true
    onTriggered: testRoot.fail("timed out waiting for valid traffic after protocol errors")
  }
}
