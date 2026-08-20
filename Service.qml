import QtQuick
import Quickshell.Io

// SystemStatsSession: Quattro creates this service once per shell session.
Item {
  id: root

  readonly property var current: _current

  property var _current: _immutable({
    schemaVersion: 1,
    generation: 0,
    sequence: 0,
    configRevision: 0,
    phase: "initializing",
    publishedAtMs: 0,
    cpu: { status: "initializing", since: 0 },
    ram: {
      status: "unavailable",
      error: {
        code: "dependencyMissing",
        scope: "ram",
        retryability: "nonRetryable",
        diagnostic: "metric provider is outside the CPU-only slice"
      },
      since: 0
    },
    gpu: {
      status: "unavailable",
      error: {
        code: "dependencyMissing",
        scope: "gpu",
        retryability: "nonRetryable",
        diagnostic: "metric provider is outside the CPU-only slice"
      },
      since: 0
    },
    source: { status: "starting" }
  })
  property double _generation: 0
  property int _sequence: 0

  function _helperPath() {
    return decodeURIComponent(String(Qt.resolvedUrl("bin/system-stats-helper")).replace(/^file:\/\//, ""))
  }

  function _immutable(value) {
    if (value === null || typeof value !== "object" || Object.isFrozen(value)) return value
    var keys = Object.keys(value)
    for (var i = 0; i < keys.length; i++) _immutable(value[keys[i]])
    return Object.freeze(value)
  }

  function _handleLine(line) {
    var message
    try {
      message = JSON.parse(String(line))
    } catch (error) {
      return
    }

    if (message.schemaVersion !== 1) return
    if (message.type === "hello") {
      if (!Number.isSafeInteger(message.generation) || message.generation <= 0) return
      _generation = message.generation
      _sequence = 0
      return
    }
    if (message.type !== "snapshot") return
    if (message.generation !== _generation) return
    if (!Number.isInteger(message.sequence) || message.sequence <= _sequence) return
    if (message.phase !== "live" && message.phase !== "degraded") return
    if (!Number.isInteger(message.publishedAtMs) || message.publishedAtMs < 0) return
    if (!_validMetric(message.cpu, true)) return
    if (!_validMetric(message.ram, false) || !_validMetric(message.gpu, false)) return
    if (!message.source || message.source.status !== "running") return
    if ((message.phase === "live") !== (message.cpu.status === "available")) return

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
    _current = _immutable(snapshot)
  }

  function _validMetric(metric, allowsAvailable) {
    if (!metric || (metric.status !== "available" && metric.status !== "unavailable")) return false
    if (metric.status === "unavailable") {
      return metric.error
        && typeof metric.error.code === "string"
        && typeof metric.error.scope === "string"
        && typeof metric.error.retryability === "string"
        && Number.isInteger(metric.since)
        && metric.since >= 0
    }
    if (!allowsAvailable) return false
    if (!metric.value
        || !Number.isInteger(metric.value.percent)
        || !Number.isInteger(metric.value.actualWindowMs)) return false
    return metric.value.percent >= 0
      && metric.value.percent <= 100
      && metric.value.actualWindowMs > 0
      && Number.isInteger(metric.sampledAtMs)
      && metric.sampledAtMs >= 0
      && metric.window
      && Number.isInteger(metric.window.actualMs)
      && metric.window.actualMs > 0
      && metric.window.actualMs === metric.value.actualWindowMs
      && typeof metric.evidence === "string"
      && typeof metric.path === "string"
  }

  Process {
    id: collector

    command: [root._helperPath()]
    stdinEnabled: true

    stdout: SplitParser {
      onRead: function(line) { root._handleLine(line) }
    }
  }

  Component.onCompleted: Qt.callLater(function() { collector.running = true })
}
