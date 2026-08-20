import QtQuick
import Quickshell
import "plugin" as SystemStats

ShellRoot {
  id: testRoot

  property bool finished: false

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

  function checkWidgets(snapshot) {
    if (finished || snapshot.sequence !== 1) return
    if (!verify(screenA.session === session, "screen A uses shared session")) return
    if (!verify(screenB.session === session, "screen B uses shared session")) return
    if (!verify(screenA.snapshotSequence === 1, "screen A sequence")) return
    if (!verify(screenB.snapshotSequence === 1, "screen B sequence")) return
    if (!verify(screenA.cpuVisible && screenB.cpuVisible, "CPU metrics visible")) return
    if (!verify(!screenA.ramVisible && !screenB.ramVisible, "RAM metrics hidden")) return
    if (!verify(!screenA.gpuVisible && !screenB.gpuVisible, "GPU metrics hidden")) return
    if (!verify(screenA.displayValue === "37", "screen A CPU value")) return
    if (!verify(screenB.displayValue === "37", "screen B CPU value")) return
    if (!verify(session.helperStartCount === 1, "one helper process")) return
    if (!verify(snapshot.source.timerCount === 1, "one sampling timer")) return

    finished = true
    console.log("TEST-PASS: two widgets share one session")
    Qt.quit()
  }

  SystemStats.Service {
    id: session

    autoStart: false
    helperCommand: [
      testRoot.localPath(Qt.resolvedUrl("plugin/bin/system-stats-helper")),
      "--frames",
      testRoot.localPath(Qt.resolvedUrl("fixtures/cpu/normal.stat")),
      "--interval-ms",
      "20"
    ]

    onSnapshotPublished: function(snapshot) { testRoot.checkWidgets(snapshot) }
  }

  QtObject {
    id: fakeShell

    function serviceFor(pluginId) {
      return pluginId === "reynkedevos.system-stats" ? session : null
    }
  }

  QtObject {
    id: fakeBar

    property var shell: fakeShell
    property bool vertical: false
    property int barSize: 26
    property string fontFamily: "JetBrainsMono Nerd Font"
    property color barForeground: "#dbe2ef"
    property color foreground: "#dbe2ef"
    property bool foregroundAnimationEnabled: false

    function registerClickTarget() {}
    function unregisterClickTarget() {}
    function showTooltip() {}
    function hideTooltip() {}
  }

  SystemStats.BarWidget {
    id: screenA
    bar: fakeBar
  }

  SystemStats.BarWidget {
    id: screenB
    bar: fakeBar
  }

  Timer {
    interval: 2000
    running: true
    onTriggered: testRoot.fail("timed out waiting for shared widget state")
  }

  Component.onCompleted: {
    if (!verify(screenA.initializing && screenB.initializing, "initialization display")) return
    if (!verify(!screenA.cpuVisible && !screenB.cpuVisible, "CPU hidden while initializing")) return
    session.start()
  }
}
