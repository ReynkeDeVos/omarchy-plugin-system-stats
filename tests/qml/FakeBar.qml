import QtQuick

QtObject {
  id: root

  required property var session
  property int persistenceCount: 0
  property var persistedGpuSelection: null
  readonly property QtObject shell: QtObject {
    readonly property QtObject pluginRegistry: QtObject {
      function setBarWidget(pluginId, key, value, selector) {
        if (pluginId !== "reynkedevos.system-stats" || key !== "gpuSelection")
          return "unexpected setting"
        root.persistenceCount++
        root.persistedGpuSelection = value
        return ""
      }
    }

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
  property var activePopout: null

  function registerClickTarget() {}
  function unregisterClickTarget() {}
  function showTooltip() {}
  function hideTooltip() {}
  function requestPopout(owner) { activePopout = owner }
  function releasePopout(owner) { if (activePopout === owner) activePopout = null }
}
