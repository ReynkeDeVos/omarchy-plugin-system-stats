import QtQuick
import Quickshell.Io

// Test-only adapter loaded as a separate temporary Quattro service plugin.
// Production SystemStatsSession and BarWidget interfaces stay acceptance-free.
Item {
  id: root

  property var shell: null
  readonly property string targetPluginId: "reynkedevos.system-stats"

  function probeState() {
    var bar = shell ? shell.bar : null
    var widgets = bar && typeof bar.moduleWidgets === "function"
      ? bar.moduleWidgets(targetPluginId) : []
    var hostService = shell && typeof shell.serviceFor === "function"
      ? shell.serviceFor(targetPluginId) : null
    var services = shell && shell._services ? shell._services : ({})
    var serviceSlots = services[targetPluginId] ? 1 : 0
    var registeredServices = []
    var registeredServiceSlotCount = 0
    for (var serviceKey in services) {
      var registeredService = services[serviceKey]
      if (!registeredService) continue
      registeredServiceSlotCount++
      if (registeredServices.indexOf(registeredService) === -1)
        registeredServices.push(registeredService)
    }
    var serviceHostChildren = []
    if (hostService && hostService.parent && hostService.parent.children) {
      for (var childIndex = 0;
           childIndex < hostService.parent.children.length; childIndex++)
        serviceHostChildren.push(hostService.parent.children[childIndex])
    }
    var targetServiceInstanceCount = 0
    var unregisteredServiceCount = 0
    for (var hostIndex = 0; hostIndex < serviceHostChildren.length; hostIndex++) {
      var serviceChild = serviceHostChildren[hostIndex]
      if (serviceChild === hostService) targetServiceInstanceCount++
      if (registeredServices.indexOf(serviceChild) === -1)
        unregisteredServiceCount++
    }
    var missingRegisteredServiceCount = 0
    for (var registeredIndex = 0;
         registeredIndex < registeredServices.length; registeredIndex++) {
      if (serviceHostChildren.indexOf(registeredServices[registeredIndex]) === -1)
        missingRegisteredServiceCount++
    }
    var serviceRegistryConsistent = registeredServiceSlotCount
        === registeredServices.length
      && serviceHostChildren.length === registeredServices.length
      && unregisteredServiceCount === 0
      && missingRegisteredServiceCount === 0
    var snapshots = []
    var widgetStates = []
    var firstGeneration = -1
    var firstSequence = -1
    var firstSettings = ""
    var allWidgetsUseHostService = hostService !== null
    var sharedSequence = true
    var sharedSettings = true

    for (var i = 0; i < widgets.length; i++) {
      var widget = widgets[i]
      if (!widget) continue
      if (widget.session !== hostService) allWidgetsUseHostService = false
      if (widget.snapshot && snapshots.indexOf(widget.snapshot) === -1)
        snapshots.push(widget.snapshot)

      var generation = widget.snapshot ? Number(widget.snapshot.generation) : -1
      var sequence = widget.snapshot ? Number(widget.snapshot.sequence) : -1
      var settings = widget.settings || {}
      var configuredIntervalSeconds = typeof widget.configuredIntervalSeconds === "function"
        ? Number(widget.configuredIntervalSeconds()) : -1
      var ramDisplayFormat = widget.ramDisplayFormat === undefined
        ? "" : String(widget.ramDisplayFormat)
      var settingsKey = JSON.stringify(settings)
      if (widgetStates.length === 0) {
        firstGeneration = generation
        firstSequence = sequence
        firstSettings = settingsKey
      } else {
        if (generation !== firstGeneration || sequence !== firstSequence)
          sharedSequence = false
        if (settingsKey !== firstSettings) sharedSettings = false
      }
      widgetStates.push({
        generation: generation,
        sequence: sequence,
        settings: settings,
        configuredIntervalSeconds: configuredIntervalSeconds,
        ramDisplayFormat: ramDisplayFormat
      })
    }

    return JSON.stringify({
      schemaVersion: 1,
      widgetCount: widgetStates.length,
      serviceSlotCount: serviceSlots,
      targetServiceInstanceCount: targetServiceInstanceCount,
      unregisteredServiceCount: unregisteredServiceCount,
      serviceRegistryConsistent: serviceRegistryConsistent,
      snapshotCount: snapshots.length,
      allWidgetsUseHostService: allWidgetsUseHostService,
      generation: firstGeneration,
      sequence: firstSequence,
      sharedSequence: sharedSequence,
      sharedSettings: sharedSettings,
      widgets: widgetStates
    })
  }

  IpcHandler {
    enabled: root.shell !== null
    target: "reynkedevos.system-stats-acceptance"

    function state(): string { return root.probeState() }
  }
}
