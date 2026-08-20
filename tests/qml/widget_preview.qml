import QtQuick
import QtQuick.Window
import Quickshell
import "plugin" as SystemStats

ShellRoot {
  id: previewRoot

  readonly property string outputDirectory: String(Quickshell.env("SYSTEM_STATS_REVIEW_DIR"))

  function localPath(url) {
    return decodeURIComponent(String(url).replace(/^file:\/\//, ""))
  }

  function capture(path, callback) {
    captureSurface.grabToImage(function(result) {
      if (!result.saveToFile(outputDirectory + "/" + path)) {
        console.error("Could not save " + path)
        Qt.quit()
        return
      }
      callback()
    }, Qt.size(720, 144))
  }

  SystemStats.Service {
    id: session

    autoStart: false
    helperCommand: [
      previewRoot.localPath(Qt.resolvedUrl("plugin/bin/system-stats-helper")),
      "--frames",
      previewRoot.localPath(Qt.resolvedUrl("fixtures/cpu/normal.stat")),
      "--interval-ms",
      "80"
    ]

    onSnapshotPublished: function(snapshot) {
      if (snapshot.sequence !== 1) return
      Qt.callLater(function() {
        previewRoot.capture("system-stats-cpu.png", Qt.quit)
      })
    }
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

  Window {
    id: previewWindow

    width: 360
    height: 72
    visible: true
    color: "transparent"

    Rectangle {
      id: captureSurface

      anchors.centerIn: parent
      width: 360
      height: 72
      color: "#10151d"

      Rectangle {
        anchors.centerIn: parent
        width: parent.width
        height: 26
        color: "#171d28"

        SystemStats.BarWidget {
          id: widget
          anchors.centerIn: parent
          bar: fakeBar
        }
      }
    }
  }

  Component.onCompleted: Qt.callLater(function() {
    previewRoot.capture("system-stats-initializing.png", function() {
      session.start()
    })
  })
}
