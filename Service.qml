import QtQuick
import Quickshell
import Quickshell.Io

// SystemStatsSession: Quattro creates this service once per shell session.
Item {
  id: root

  readonly property var current: _current

  signal commandSettled(int commandId, bool accepted, string errorCode)

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
  property int _configRevision: 0
  property int _intervalSeconds: 2
  property int _nextCommandId: 1
  property var _pendingConfigurations: ({})
  readonly property int _secondMs: {
    var configured = Number(Quickshell.env("SYSTEM_STATS_SECOND_MS"))
    return Number.isInteger(configured) && configured > 0 ? configured : 1000
  }
  readonly property int _watchdogTickMs: Math.max(1, Math.min(100, Math.floor(_secondMs / 4)))
  property double _cpuStateStartedAtMs: 0
  property double _lastCpuSuccessfulAt: -1
  property double _helperClockOffsetMs: 0
  property bool _hasHelperClockOffset: false
  property bool _helloReceived: false
  property double _expectedSampleAtMs: -1
  property double _failureSince: -1
  property string _terminationReason: ""
  property int _backoffIndex: 0
  readonly property var _backoffSeconds: [1, 2, 4, 8, 16, 30]
  property string _stdoutBuffer: ""
  property int _stdoutBufferBytes: 0
  property bool _discardingStdoutLine: false

  function _helperPath() {
    return decodeURIComponent(String(Qt.resolvedUrl("bin/system-stats-helper")).replace(/^file:\/\//, ""))
  }

  function configure(settings) {
    var commandId = _nextCommandId++
    if (!settings
        || !Number.isSafeInteger(settings.configRevision)
        || settings.configRevision < 0
        || !Number.isInteger(settings.intervalSeconds)
        || settings.intervalSeconds < 2
        || settings.intervalSeconds > 10) {
      commandSettled(commandId, false, "invalidConfiguration")
      return commandId
    }

    var command = {
      type: "configure",
      schemaVersion: 1,
      generation: _generation,
      commandId: commandId,
      configRevision: settings.configRevision,
      intervalSeconds: settings.intervalSeconds
    }
    _pendingConfigurations[commandId] = command
    if (collector.running && _generation > 0) _sendConfiguration(command)
    return commandId
  }

  function _sendConfiguration(command) {
    command.generation = _generation
    command.sentGeneration = _generation
    collector.write(JSON.stringify({
      type: command.type,
      schemaVersion: command.schemaVersion,
      generation: command.generation,
      commandId: command.commandId,
      configRevision: command.configRevision,
      intervalSeconds: command.intervalSeconds
    }) + "\n")
  }

  function _sendPendingConfigurations() {
    var commandIds = Object.keys(_pendingConfigurations)
    for (var i = 0; i < commandIds.length; i++) {
      var command = _pendingConfigurations[commandIds[i]]
      if (command.sentGeneration !== _generation) _sendConfiguration(command)
    }
  }

  function _sendActiveConfiguration() {
    if (_configRevision === 0 && _intervalSeconds === 2) return
    var pendingIds = Object.keys(_pendingConfigurations)
    for (var i = 0; i < pendingIds.length; i++) {
      var pending = _pendingConfigurations[pendingIds[i]]
      if (pending.silent
          && pending.configRevision === _configRevision
          && pending.intervalSeconds === _intervalSeconds) {
        _sendConfiguration(pending)
        return
      }
    }
    var commandId = _nextCommandId++
    var command = {
      type: "configure",
      schemaVersion: 1,
      generation: _generation,
      commandId: commandId,
      configRevision: _configRevision,
      intervalSeconds: _intervalSeconds,
      silent: true
    }
    _pendingConfigurations[commandId] = command
    _sendConfiguration(command)
  }

  function _immutable(value) {
    if (value === null || typeof value !== "object" || Object.isFrozen(value)) return value
    var keys = Object.keys(value)
    for (var i = 0; i < keys.length; i++) _immutable(value[keys[i]])
    return Object.freeze(value)
  }

  function _publishSnapshotChanges(changes) {
    var snapshot = {
      schemaVersion: _current.schemaVersion,
      generation: _current.generation,
      sequence: _current.sequence,
      configRevision: _current.configRevision,
      phase: _current.phase,
      publishedAtMs: _current.publishedAtMs,
      cpu: _current.cpu,
      ram: _current.ram,
      gpu: _current.gpu,
      source: _current.source
    }
    var keys = Object.keys(changes)
    for (var i = 0; i < keys.length; i++) snapshot[keys[i]] = changes[keys[i]]
    _current = _immutable(snapshot)
  }

  function _nowMs() {
    return serviceClock.elapsedMs()
  }

  function _helperNowMs() {
    return Math.max(0, Math.floor(_nowMs() + _helperClockOffsetMs))
  }

  function _observeHelperClock(helperAtMs, receivedAtMs) {
    var candidate = helperAtMs - receivedAtMs
    if (!_hasHelperClockOffset || candidate > _helperClockOffsetMs) {
      _helperClockOffsetMs = candidate
      _hasHelperClockOffset = true
    }
  }

  function _withLastCpuSuccess(metric) {
    if (metric.status !== "unavailable" || _lastCpuSuccessfulAt < 0) return metric
    return {
      status: metric.status,
      error: metric.error,
      since: metric.since,
      lastSuccessfulAt: _lastCpuSuccessfulAt
    }
  }

  function _staleCpuMetric() {
    var stale = {
      status: "unavailable",
      error: {
        code: "stale",
        scope: "cpu",
        retryability: "retryable",
        pathId: "proc-stat"
      },
      since: _helperNowMs()
    }
    if (_lastCpuSuccessfulAt >= 0) stale.lastSuccessfulAt = _lastCpuSuccessfulAt
    return stale
  }

  function _publishStaleCpu() {
    _publishSnapshotChanges({
      phase: "degraded",
      publishedAtMs: _helperNowMs(),
      cpu: _staleCpuMetric()
    })
  }

  function _sourceError(code) {
    return {
      code: code,
      scope: "source",
      retryability: "retryable"
    }
  }

  function _publishSource(source) {
    _publishSnapshotChanges({
      generation: _generation > 0 ? _generation : _current.generation,
      sequence: _generation > 0 ? _sequence : _current.sequence,
      publishedAtMs: _helperNowMs(),
      source: source
    })
  }

  function _publishProtocolError() {
    var source = {
      status: collector.running ? "running" : "starting",
      error: _sourceError("protocolError")
    }
    if (_lastCpuSuccessfulAt >= 0) source.lastSuccessfulAt = _lastCpuSuccessfulAt
    _publishSource(source)
  }

  function _collectorFailureSource(code, status, failureAt, nextRestartAt) {
    var source = {
      status: status,
      error: _sourceError(code),
      failureAt: failureAt
    }
    if (_lastCpuSuccessfulAt >= 0) source.lastSuccessfulAt = _lastCpuSuccessfulAt
    if (nextRestartAt >= 0) source.nextRestartAt = nextRestartAt
    return source
  }

  function _publishCollectorFailure(code, status, failureAt, nextRestartAt) {
    if (_failureSince < 0) _failureSince = _helperNowMs()
    var cpu = {
      status: "unavailable",
      error: {
        code: code,
        scope: "cpu",
        retryability: "retryable",
        pathId: "proc-stat"
      },
      since: _failureSince
    }
    if (_lastCpuSuccessfulAt >= 0) cpu.lastSuccessfulAt = _lastCpuSuccessfulAt
    _publishSnapshotChanges({
      phase: "degraded",
      publishedAtMs: _helperNowMs(),
      cpu: cpu,
      source: _collectorFailureSource(code, status, failureAt, nextRestartAt)
    })
  }

  function _checkFreshness() {
    var ageMs
    if (_current.cpu.status === "initializing") {
      ageMs = _nowMs() - _cpuStateStartedAtMs
    } else if (_current.cpu.status === "available") {
      ageMs = _helperNowMs() - _lastCpuSuccessfulAt
    } else {
      ageMs = -1
    }
    if (ageMs >= 4 * _secondMs) _publishStaleCpu()

    if (collector.running
        && _expectedSampleAtMs >= 0
        && _nowMs() >= _expectedSampleAtMs + 2 * _secondMs) {
      _stopUnresponsiveCollector()
    }
  }

  function _stopUnresponsiveCollector() {
    if (_terminationReason !== "") return
    _terminationReason = "collectorUnresponsive"
    var failedAt = _helperNowMs()
    _failureSince = _helperNowMs()
    _publishCollectorFailure(_terminationReason, "running", failedAt, -1)
    stableTimer.stop()
    collector.running = false
    terminationTimer.restart()
  }

  function _onCollectorStarted() {
    restartTimer.stop()
    terminationTimer.stop()
    _generation = 0
    _sequence = 0
    _helloReceived = false
    _terminationReason = ""
    _failureSince = -1
    _cpuStateStartedAtMs = _nowMs()
    _expectedSampleAtMs = _nowMs() + _intervalSeconds * _secondMs
    _publishSource({ status: "starting" })
    _hasHelperClockOffset = false
    _stdoutBuffer = ""
    _stdoutBufferBytes = 0
    _discardingStdoutLine = false
    stableTimer.restart()
  }

  function _onCollectorExited() {
    terminationTimer.stop()
    stableTimer.stop()
    _helloReceived = false
    _expectedSampleAtMs = -1
    _stdoutBuffer = ""
    _stdoutBufferBytes = 0
    _discardingStdoutLine = false
    var code = _terminationReason !== "" ? _terminationReason : "collectorExited"
    _terminationReason = ""
    var failureAt = _helperNowMs()
    var backoffPosition = Math.min(_backoffIndex, _backoffSeconds.length - 1)
    var delayMs = _backoffSeconds[backoffPosition] * _secondMs
    _backoffIndex++
    _publishCollectorFailure(code, "backoff", failureAt, failureAt + delayMs)
    restartTimer.interval = delayMs
    restartTimer.restart()
  }

  function _utf8ByteLength(value, limit) {
    var bytes = 0
    for (var i = 0; i < value.length; i++) {
      var code = value.charCodeAt(i)
      if (code <= 0x7f) {
        bytes++
      } else if (code <= 0x7ff) {
        bytes += 2
      } else if (code >= 0xd800 && code <= 0xdbff) {
        if (i + 1 >= value.length) return limit + 1
        var low = value.charCodeAt(++i)
        if (low < 0xdc00 || low > 0xdfff) return limit + 1
        bytes += 4
      } else if (code >= 0xdc00 && code <= 0xdfff) {
        return limit + 1
      } else {
        bytes += 3
      }
      if (bytes > limit) return bytes
    }
    return bytes
  }

  function _handleChunk(chunk) {
    var data = String(chunk)
    var offset = 0
    while (offset < data.length) {
      var newline = data.indexOf("\n", offset)
      var end = newline >= 0 ? newline : data.length
      var segment = data.substring(offset, end)
      if (!_discardingStdoutLine) {
        var candidate = _stdoutBuffer + segment
        var candidateBytes = _utf8ByteLength(candidate, 65536)
        if (candidateBytes > 65536) {
          _stdoutBuffer = ""
          _stdoutBufferBytes = 0
          _discardingStdoutLine = true
          _publishProtocolError()
        } else {
          _stdoutBuffer = candidate
          _stdoutBufferBytes = candidateBytes
        }
      }

      if (newline >= 0) {
        if (!_discardingStdoutLine) _handleLine(_stdoutBuffer)
        _stdoutBuffer = ""
        _stdoutBufferBytes = 0
        _discardingStdoutLine = false
        offset = newline + 1
      } else {
        offset = data.length
      }
    }
  }

  function _handleLine(line) {
    if (!collector.running) return
    if (String(line).length > 65536) {
      _publishProtocolError()
      return
    }
    var message
    try {
      message = JSON.parse(String(line))
    } catch (error) {
      _publishProtocolError()
      return
    }

    if (!message || typeof message !== "object" || message.schemaVersion !== 1) {
      _publishProtocolError()
      return
    }
    if (message.type === "hello") {
      if (_helloReceived
          || !Number.isSafeInteger(message.generation)
          || message.generation <= 0
          || !Number.isSafeInteger(message.publishedAtMs)
          || message.publishedAtMs < 0) {
        _publishProtocolError()
        return
      }
      _helloReceived = true
      _generation = message.generation
      _sequence = 0
      _observeHelperClock(message.publishedAtMs, _nowMs())
      _publishSource({ status: "running" })
      _sendActiveConfiguration()
      _sendPendingConfigurations()
      return
    }
    if (message.type === "ack" || message.type === "reject") {
      _handleCommandResult(message)
      return
    }
    if (message.type !== "snapshot"
        || !_helloReceived
        || message.generation !== _generation
        || !Number.isSafeInteger(message.sequence)
        || message.sequence <= _sequence
        || (message.phase !== "initializing"
            && message.phase !== "live"
            && message.phase !== "degraded")
        || !Number.isSafeInteger(message.configRevision)
        || message.configRevision < 0
        || message.configRevision !== _configRevision
        || !Number.isSafeInteger(message.publishedAtMs)
        || message.publishedAtMs < 0
        || !_validMetric(message.cpu, true)
        || !_validMetric(message.ram, false)
        || !_validMetric(message.gpu, false)
        || !message.source
        || message.source.status !== "running"
        || ((message.phase === "initializing") !== (message.cpu.status === "initializing"))
        || ((message.phase === "live") !== (message.cpu.status === "available"))
        || ((message.phase === "degraded") !== (message.cpu.status === "unavailable"))) {
      _publishProtocolError()
      return
    }

    var receivedAtMs = _nowMs()
    _observeHelperClock(message.publishedAtMs, receivedAtMs)
    var cpuMetric = message.cpu
    var snapshotPhase = message.phase
    if (cpuMetric.status === "available") {
      _lastCpuSuccessfulAt = cpuMetric.sampledAtMs
      if (_helperNowMs() - _lastCpuSuccessfulAt >= 4 * _secondMs) {
        cpuMetric = _staleCpuMetric()
        snapshotPhase = "degraded"
      }
    } else {
      _cpuStateStartedAtMs = receivedAtMs
      cpuMetric = _withLastCpuSuccess(cpuMetric)
    }
    if (message.phase !== "initializing") {
      _expectedSampleAtMs = receivedAtMs + _intervalSeconds * _secondMs
    }
    _failureSince = -1

    _sequence = message.sequence
    _publishSnapshotChanges({
      schemaVersion: message.schemaVersion,
      generation: message.generation,
      sequence: message.sequence,
      configRevision: message.configRevision,
      phase: snapshotPhase,
      publishedAtMs: message.publishedAtMs,
      cpu: cpuMetric,
      ram: message.ram,
      gpu: message.gpu,
      source: { status: "running" }
    })
  }

  function _handleCommandResult(message) {
    if (!_helloReceived
        || message.generation !== _generation
        || !Number.isSafeInteger(message.commandId)
        || message.commandId <= 0) {
      _publishProtocolError()
      return
    }
    var command = _pendingConfigurations[message.commandId]
    if (!command) {
      _publishProtocolError()
      return
    }
    delete _pendingConfigurations[message.commandId]

    if (message.type === "reject") {
      var rejectCode = message.error === "invalidConfiguration"
        ? message.error : "protocolError"
      if (!command.silent) commandSettled(message.commandId, false, rejectCode)
      if (rejectCode === "protocolError") _publishProtocolError()
      return
    }
    if (message.configRevision !== command.configRevision
        || message.intervalSeconds !== command.intervalSeconds) {
      if (!command.silent) commandSettled(message.commandId, false, "protocolError")
      _publishProtocolError()
      return
    }
    _configRevision = command.configRevision
    _intervalSeconds = command.intervalSeconds
    _expectedSampleAtMs = _nowMs() + _intervalSeconds * _secondMs
    if (!command.silent) commandSettled(message.commandId, true, "")
  }

  function _validMetric(metric, allowsAvailable) {
    if (!metric
        || (metric.status !== "initializing"
            && metric.status !== "available"
            && metric.status !== "unavailable")) return false
    if (metric.status === "initializing") {
      return allowsAvailable && Number.isInteger(metric.since) && metric.since >= 0
    }
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
      // Empty splitting exposes bounded chunks instead of buffering an unterminated line.
      splitMarker: ""
      onRead: function(chunk) { root._handleChunk(chunk) }
    }

    onStarted: root._onCollectorStarted()
    // Tooling cannot resolve QProcess::ExitStatus from Quickshell's generated types.
    // qmllint disable signal-handler-parameters
    onExited: root._onCollectorExited()
    // qmllint enable signal-handler-parameters
  }

  ElapsedTimer { id: serviceClock }

  Timer {
    interval: root._watchdogTickMs
    repeat: true
    running: true
    onTriggered: root._checkFreshness()
  }

  Timer {
    id: restartTimer

    onTriggered: {
      if (!collector.running) collector.running = true
    }
  }

  Timer {
    id: terminationTimer

    interval: root._secondMs
    onTriggered: {
      if (collector.running) collector.signal(9)
    }
  }

  Timer {
    id: stableTimer

    interval: 60 * root._secondMs
    onTriggered: root._backoffIndex = 0
  }

  Component.onCompleted: Qt.callLater(function() { collector.running = true })
}
