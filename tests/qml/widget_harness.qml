import QtQuick
import Quickshell
import "plugin" as SystemStats

ShellRoot {
  id: testRoot

  property bool finished: false
  property bool ready: false

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

  function checkWidgets(snapshot) {
    if (finished || ready || snapshot.sequence !== 1) return
    if (!verify(fakeBarA !== fakeBarB, "screens have distinct bar callers")) return
    if (!verify(screenA.bar === fakeBarA, "screen A owns bar A")) return
    if (!verify(screenB.bar === fakeBarB, "screen B owns bar B")) return
    if (!verify(screenA.session === session, "screen A uses shared session")) return
    if (!verify(screenB.session === session, "screen B uses shared session")) return
    if (!verify(screenA.snapshotSequence === 1, "screen A sequence")) return
    if (!verify(screenB.snapshotSequence === 1, "screen B sequence")) return
    if (!verify(screenA.cpuVisible && screenB.cpuVisible, "CPU metrics visible")) return
    if (!verify(!screenA.ramVisible && !screenB.ramVisible, "RAM metrics hidden")) return
    if (!verify(!screenA.gpuVisible && !screenB.gpuVisible, "GPU metrics hidden")) return
    if (!verify(screenA.displayValue === "37", "screen A CPU value")) return
    if (!verify(screenB.displayValue === "37", "screen B CPU value")) return

    ready = true
    console.log("TEST-READY: two widgets share one session")
    finishTimer.start()
  }

  SystemStats.Service {
    id: session
  }

  Connections {
    target: session
    function onCurrentChanged() { testRoot.checkWidgets(session.current) }
  }

  FakeBar {
    id: fakeBarA
    session: session
  }

  FakeBar {
    id: fakeBarB
    session: session
  }

  SystemStats.BarWidget {
    id: screenA
    bar: fakeBarA
  }

  SystemStats.BarWidget {
    id: screenB
    bar: fakeBarB
  }

  Timer {
    id: finishTimer

    interval: 1000
    onTriggered: {
      testRoot.finished = true
      console.log("TEST-PASS: two widgets share one session")
      Qt.quit()
    }
  }

  Timer {
    interval: 2000
    running: true
    onTriggered: testRoot.fail("timed out waiting for shared widget state")
  }

  Component.onCompleted: {
    if (!verify(screenA.initializing && screenB.initializing, "initialization display")) return
    if (!verify(!screenA.cpuVisible && !screenB.cpuVisible, "CPU hidden while initializing")) return
  }
}
