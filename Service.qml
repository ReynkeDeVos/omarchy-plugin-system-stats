import QtQuick
import Quickshell.Io

// SystemStatsSession: Quattro creates this service once per shell session.
Item {
  id: root

  property bool autoStart: true
  property var helperCommand: [helperPath()]

  readonly property var current: _current
  readonly property int helperStartCount: _helperStartCount
  readonly property var helperProcessId: collector.processId

  property var _current: immutable({
    schemaVersion: 1,
    generation: 0,
    sequence: 0,
    configRevision: 0,
    phase: "initializing",
    publishedAtMs: 0,
    cpu: { status: "initializing" },
    ram: { status: "unavailable", error: "notImplemented" },
    gpu: { status: "unavailable", error: "notImplemented" },
    source: { status: "starting" }
  })
  property int _helperStartCount: 0
  property int _generation: 0
  property int _sequence: 0

  signal snapshotPublished(var snapshot)

  function helperPath() {
    return decodeURIComponent(String(Qt.resolvedUrl("bin/system-stats-helper")).replace(/^file:\/\//, ""))
  }

  function immutable(value) {
    if (value === null || typeof value !== "object" || Object.isFrozen(value)) return value
    var keys = Object.keys(value)
    for (var i = 0; i < keys.length; i++) immutable(value[keys[i]])
    return Object.freeze(value)
  }

  function start() {
    if (collector.running) return
    collector.running = true
  }

  function handleLine(line) {
    var message
    try {
      message = JSON.parse(String(line))
    } catch (error) {
      return
    }

    if (message.schemaVersion !== 1) return
    if (message.type === "hello") {
      if (!Number.isInteger(message.generation) || message.generation <= 0) return
      _generation = message.generation
      _sequence = 0
      return
    }
    if (message.type !== "snapshot") return
    if (message.generation !== _generation) return
    if (!Number.isInteger(message.sequence) || message.sequence <= _sequence) return
    if (!validCpuMetric(message.cpu)) return

    var snapshot = {
      schemaVersion: message.schemaVersion,
      generation: message.generation,
      sequence: message.sequence,
      configRevision: 0,
      phase: message.phase,
      publishedAtMs: message.publishedAtMs,
      cpu: message.cpu,
      ram: message.ram,
      gpu: message.gpu,
      source: message.source
    }
    _sequence = message.sequence
    _current = immutable(snapshot)
    snapshotPublished(_current)
  }

  function validCpuMetric(metric) {
    if (!metric || (metric.status !== "available" && metric.status !== "unavailable")) return false
    if (metric.status === "unavailable") return typeof metric.error === "string"
    if (!metric.value || !Number.isInteger(metric.value.percent)) return false
    return metric.value.percent >= 0 && metric.value.percent <= 100
  }

  Process {
    id: collector

    command: root.helperCommand
    stdinEnabled: true

    stdout: SplitParser {
      onRead: function(line) { root.handleLine(line) }
    }

    onStarted: root._helperStartCount++
  }

  Component.onCompleted: {
    if (autoStart) Qt.callLater(start)
  }
}
