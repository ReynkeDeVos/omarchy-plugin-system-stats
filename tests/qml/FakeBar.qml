import QtQuick

QtObject {
  id: root

  required property var session
  readonly property QtObject shell: QtObject {
    function serviceFor(pluginId) {
      return pluginId === "reynkedevos.system-stats" ? root.session : null
    }
  }

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
