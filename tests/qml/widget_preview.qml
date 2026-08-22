import QtQuick
import QtQuick.Window
import Quickshell
import "plugin" as SystemStats

ShellRoot {
  id: previewRoot

  readonly property string outputDirectory: String(Quickshell.env("SYSTEM_STATS_REVIEW_DIR"))

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
  }

  Connections {
    target: session
    function onCurrentChanged() {
      if (session.current.sequence !== 1) return
      Qt.callLater(function() {
        previewRoot.capture("system-stats-percent.png", function() {
          widget.settings = ({ ramDisplayFormat: "gib" })
          Qt.callLater(function() {
            previewRoot.capture("system-stats-gib.png", Qt.quit)
          })
        })
      })
    }
  }

  FakeBar {
    id: fakeBar
    session: session
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
    previewRoot.capture("system-stats-initializing.png", function() {})
  })
}
