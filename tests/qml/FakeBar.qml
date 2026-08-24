import QtQuick

QtObject {
  id: root

  required property var session
  property int persistenceCount: 0
  property var persistedGpuSelection: null
  property var persistedSettings: ({})
  property int runCount: 0
  property string lastCommand: ""
  property bool runResult: true
  property var peerWidgets: []
  property var persistedShellConfig: null
  readonly property QtObject shell: QtObject {
    readonly property var shellConfig: root.persistedShellConfig
    readonly property QtObject pluginRegistry: QtObject {
      function setBarWidget(pluginId, key, value, selector) {
        if (pluginId !== "reynkedevos.system-stats"
            || (key !== "gpuSelection" && key !== "intervalSeconds"
                && key !== "ramDisplayFormat"))
          return "unexpected setting"
        root.persistenceCount++
        var next = Object.assign({}, root.persistedSettings)
        next[key] = value
        root.persistedSettings = next
        if (key === "gpuSelection") root.persistedGpuSelection = value
        return ""
      }
    }

    function serviceFor(pluginId) {
      return pluginId === "reynkedevos.system-stats" ? root.session : null
    }
  }

  property bool vertical: false
  property string position: "top"
  property int barSize: 26
  property string fontFamily: "JetBrainsMono Nerd Font"
  property color barForeground: "#dbe2ef"
  property color foreground: "#dbe2ef"
  property bool foregroundAnimationEnabled: false
  property var activePopout: null

  function registerClickTarget() {}
  function unregisterClickTarget() {}
  function moduleWidgets() { return peerWidgets }
  function run(command) {
    runCount++
    lastCommand = String(command)
    return runResult
  }
  function showTooltip() {}
  function hideTooltip() {}
  function requestPopout(owner) { activePopout = owner }
  function releasePopout(owner) { if (activePopout === owner) activePopout = null }
}
