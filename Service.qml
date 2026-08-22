import QtQuick
import Quickshell
import Quickshell.Io

// SystemStatsSession: Quattro creates this service once per shell session.
Item {
  id: root

  readonly property var current: _current
  readonly property var gpuInventory: _gpuInventory

  signal commandSettled(int commandId, bool accepted, string errorCode)

  property var _current: _immutable({
    schemaVersion: 1,
    generation: 0,
    sequence: 0,
    configRevision: 0,
    phase: "initializing",
    publishedAtMs: 0,
    cpu: { status: "initializing", since: 0 },
    ram: { status: "initializing", since: 0 },
    gpu: {
      status: "unavailable",
      error: {
        code: "dependencyMissing",
        scope: "gpu",
        retryability: "nonRetryable",
        diagnostic: "metric provider is outside the CPU and RAM slice"
      },
      since: 0
    },
    selection: { mode: "auto", status: "none" },
    source: { status: "starting" }
  })
  property var _gpuInventory: _immutable({
    revision: 0,
    discoveredAtMs: 0,
    devices: []
  })
  property double _generation: 0
  property double _gpuInventoryGeneration: 0
  property int _sequence: 0
  property int _configRevision: 0
  property int _intervalSeconds: 2
  property string _gpuSelectionMode: "auto"
  property string _gpuStableId: ""
  property bool _hasGpuSessionState: false
  property string _sessionAutoStatus: "none"
  property string _sessionAutoStableId: ""
  property int _fixedGpuRetryStage: 0
  property double _fixedGpuRetryAt: -1
  property bool _awaitingGpuResume: false
  property var _provisionalGpuInventory: null
  property int _nextCommandId: 1
  property var _pendingConfigurations: ({})
  property var _pendingGpuInventoryRefreshes: ({})
  readonly property int _secondMs: {
    var configured = Number(Quickshell.env("SYSTEM_STATS_SECOND_MS"))
    return Number.isInteger(configured) && configured > 0 ? configured : 1000
  }
  readonly property int _watchdogTickMs: Math.max(1, Math.min(100, Math.floor(_secondMs / 4)))
  property double _cpuStateStartedAtMs: 0
  property double _ramStateStartedAtMs: 0
  property double _lastCpuSuccessfulAt: -1
  property double _lastRamSuccessfulAt: -1
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
    var gpuSelection = settings && settings.gpuSelection !== undefined
      ? settings.gpuSelection
      : { mode: _gpuSelectionMode, stableId: _gpuStableId }
    if (!settings
        || !Number.isSafeInteger(settings.configRevision)
        || settings.configRevision < 0
        || !Number.isInteger(settings.intervalSeconds)
        || settings.intervalSeconds < 2
        || settings.intervalSeconds > 10
        || !_validGpuSelectionPolicy(gpuSelection)) {
      commandSettled(commandId, false, "invalidConfiguration")
      return commandId
    }

    var command = {
      type: "configure",
      schemaVersion: 1,
      generation: _generation,
      commandId: commandId,
      configRevision: settings.configRevision,
      intervalSeconds: settings.intervalSeconds,
      gpuSelection: gpuSelection.mode === "fixed"
        ? { mode: "fixed", stableId: String(gpuSelection.stableId) }
        : { mode: "auto" }
    }
    _pendingConfigurations[commandId] = command
    if (collector.running && _generation > 0) _sendConfiguration(command)
    return commandId
  }

  function refreshGpuInventory() {
    var commandId = _nextCommandId++
    var command = {
      type: "refreshGpuInventory",
      schemaVersion: 1,
      generation: _generation,
      commandId: commandId
    }
    _pendingGpuInventoryRefreshes[commandId] = command
    if (collector.running && _generation > 0) _sendGpuInventoryRefresh(command)
    return commandId
  }

  function _validStableGpuId(stableId) {
    if (typeof stableId !== "string") return false
    return /^pci:[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$/.test(stableId)
      || /^nvidia:GPU-[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$/.test(stableId)
  }

  function _validGpuSelectionPolicy(selection) {
    if (!selection || typeof selection !== "object") return false
    if (selection.mode === "auto") return true
    return selection.mode === "fixed" && _validStableGpuId(selection.stableId)
  }

  function _sendConfiguration(command) {
    command.generation = _generation
    command.sentGeneration = _generation
    var payload = {
      type: command.type,
      schemaVersion: command.schemaVersion,
      generation: command.generation,
      commandId: command.commandId,
      configRevision: command.configRevision,
      intervalSeconds: command.intervalSeconds,
      gpuSelection: command.gpuSelection
    }
    if (command.silent) {
      var resume = _gpuResumeForActiveConfiguration()
      if (resume !== null) payload.gpuResume = resume
    }
    collector.write(JSON.stringify(payload) + "\n")
  }

  function _sendGpuInventoryRefresh(command) {
    command.generation = _generation
    command.sentGeneration = _generation
    collector.write(JSON.stringify({
      type: command.type,
      schemaVersion: command.schemaVersion,
      generation: command.generation,
      commandId: command.commandId
    }) + "\n")
  }

  function _sendPendingConfigurations() {
    var commandIds = Object.keys(_pendingConfigurations)
    for (var i = 0; i < commandIds.length; i++) {
      var command = _pendingConfigurations[commandIds[i]]
      if (command.sentGeneration !== _generation) _sendConfiguration(command)
    }
  }

  function _sendPendingGpuInventoryRefreshes() {
    var commandIds = Object.keys(_pendingGpuInventoryRefreshes)
    for (var i = 0; i < commandIds.length; i++) {
      var command = _pendingGpuInventoryRefreshes[commandIds[i]]
      if (command.sentGeneration !== _generation) _sendGpuInventoryRefresh(command)
    }
  }

  function _sendActiveConfiguration() {
    var resume = _gpuResumeForActiveConfiguration()
    if (_configRevision === 0 && _intervalSeconds === 2
        && _gpuSelectionMode === "auto" && resume === null) return
    var pendingIds = Object.keys(_pendingConfigurations)
    for (var i = 0; i < pendingIds.length; i++) {
      var pending = _pendingConfigurations[pendingIds[i]]
      if (pending.silent
          && pending.configRevision === _configRevision
          && pending.intervalSeconds === _intervalSeconds
          && pending.gpuSelection.mode === _gpuSelectionMode
          && String(pending.gpuSelection.stableId || "") === _gpuStableId) {
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
      gpuSelection: _gpuSelectionMode === "fixed"
        ? { mode: "fixed", stableId: _gpuStableId }
        : { mode: "auto" },
      silent: true
    }
    _pendingConfigurations[commandId] = command
    _sendConfiguration(command)
  }

  function _gpuResumeForActiveConfiguration() {
    if (!_hasGpuSessionState) return null
    if (_gpuSelectionMode === "auto") {
      return _sessionAutoStatus === "selected"
        ? { autoStatus: "selected", stableId: _sessionAutoStableId }
        : { autoStatus: _sessionAutoStatus }
    }
    return {
      fixedRetryStage: _fixedGpuRetryStage,
      fixedRetryAt: _fixedGpuRetryAt
    }
  }

  function _publicGpuSelection(selection) {
    return selection.stableId === undefined
      ? { mode: selection.mode, status: selection.status }
      : {
          mode: selection.mode,
          status: selection.status,
          stableId: selection.stableId
        }
  }

  function _captureGpuSessionState(state) {
    _hasGpuSessionState = true
    if (state.selection.mode === "auto") {
      _sessionAutoStatus = state.selection.status
      _sessionAutoStableId = state.selection.status === "selected"
        ? state.selection.stableId : ""
      _fixedGpuRetryStage = 0
      _fixedGpuRetryAt = -1
      return
    }
    _sessionAutoStatus = "none"
    _sessionAutoStableId = ""
    _fixedGpuRetryStage = state.fixedRetryStage
    _fixedGpuRetryAt = state.fixedRetryAt
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
      selection: _current.selection,
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

  function _withLastSuccess(metric, lastSuccessfulAt) {
    if (metric.status !== "unavailable" || lastSuccessfulAt < 0) return metric
    return {
      status: metric.status,
      error: metric.error,
      since: metric.since,
      lastSuccessfulAt: lastSuccessfulAt
    }
  }

  function _unavailableMetric(code, scope, pathId, since, lastSuccessfulAt) {
    var metric = {
      status: "unavailable",
      error: {
        code: code,
        scope: scope,
        retryability: "retryable",
        pathId: pathId
      },
      since: since
    }
    if (lastSuccessfulAt >= 0) metric.lastSuccessfulAt = lastSuccessfulAt
    return metric
  }

  function _metricAgeMs(metric, stateStartedAtMs, lastSuccessfulAt) {
    if (metric.status === "initializing") return _nowMs() - stateStartedAtMs
    if (metric.status === "available") return _helperNowMs() - lastSuccessfulAt
    return -1
  }

  function _normalizeMetric(metric, scope, pathId, receivedAtMs,
                            stateStartedAtMs, lastSuccessfulAt) {
    var normalized = metric
    if (metric.status === "available") {
      lastSuccessfulAt = metric.sampledAtMs
      if (_helperNowMs() - lastSuccessfulAt >= 4 * _secondMs) {
        normalized = _unavailableMetric("stale", scope, pathId,
                                        _helperNowMs(), lastSuccessfulAt)
      }
    } else {
      stateStartedAtMs = receivedAtMs
      normalized = _withLastSuccess(metric, lastSuccessfulAt)
    }
    return {
      metric: normalized,
      stateStartedAtMs: stateStartedAtMs,
      lastSuccessfulAt: lastSuccessfulAt
    }
  }

  function _phaseForMetrics(cpu, ram) {
    if (cpu.status === "initializing" && ram.status === "initializing") return "initializing"
    return cpu.status === "available" && ram.status === "available" ? "live" : "degraded"
  }

  function _publishStaleMetrics(cpu, ram) {
    _publishSnapshotChanges({
      phase: _phaseForMetrics(cpu, ram),
      publishedAtMs: _helperNowMs(),
      cpu: cpu,
      ram: ram
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
    var cpu = _unavailableMetric(code, "cpu", "proc-stat", _failureSince,
                                 _lastCpuSuccessfulAt)
    var ram = _unavailableMetric(code, "ram", "proc-meminfo", _failureSince,
                                 _lastRamSuccessfulAt)
    _publishSnapshotChanges({
      phase: "degraded",
      publishedAtMs: _helperNowMs(),
      cpu: cpu,
      ram: ram,
      source: _collectorFailureSource(code, status, failureAt, nextRestartAt)
    })
  }

  function _checkFreshness() {
    var cpuAgeMs = _metricAgeMs(_current.cpu, _cpuStateStartedAtMs,
                                _lastCpuSuccessfulAt)
    var ramAgeMs = _metricAgeMs(_current.ram, _ramStateStartedAtMs,
                                _lastRamSuccessfulAt)
    var now = _helperNowMs()
    var cpu = cpuAgeMs >= 4 * _secondMs
      ? _unavailableMetric("stale", "cpu", "proc-stat", now,
                           _lastCpuSuccessfulAt)
      : _current.cpu
    var ram = ramAgeMs >= 4 * _secondMs
      ? _unavailableMetric("stale", "ram", "proc-meminfo", now,
                           _lastRamSuccessfulAt)
      : _current.ram
    if (cpu !== _current.cpu || ram !== _current.ram) _publishStaleMetrics(cpu, ram)

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
    _ramStateStartedAtMs = _nowMs()
    _expectedSampleAtMs = _nowMs() + _intervalSeconds * _secondMs
    _publishSource({ status: "starting" })
    _hasHelperClockOffset = false
    _stdoutBuffer = ""
    _stdoutBufferBytes = 0
    _discardingStdoutLine = false
    _awaitingGpuResume = false
    _provisionalGpuInventory = null
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
      _awaitingGpuResume = _gpuResumeForActiveConfiguration() !== null
      _sendActiveConfiguration()
      _sendPendingConfigurations()
      _sendPendingGpuInventoryRefreshes()
      return
    }
    if (message.type === "gpuInventory") {
      _handleGpuInventory(message)
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
        || !_validCpuMetric(message.cpu)
        || !_validRamMetric(message.ram)
        || !_validGpuMetric(message.gpu)
        || !_validGpuSelectionState(message.selection)
        || (message.gpuState !== undefined
            && (!_validGpuSessionState(message.gpuState)
                || !_sameGpuSelectionState(message.gpuState.selection,
                                           message.selection)))
        || !message.source
        || message.source.status !== "running"
        || (message.cpu.status === "available"
            && message.ram.status === "available"
            && (message.cpu.sampledAtMs !== message.ram.sampledAtMs
                || message.cpu.window.actualMs !== message.ram.window.actualMs))
        || message.phase !== _phaseForMetrics(message.cpu, message.ram)) {
      _publishProtocolError()
      return
    }

    var receivedAtMs = _nowMs()
    _observeHelperClock(message.publishedAtMs, receivedAtMs)
    var cpuLifecycle = _normalizeMetric(message.cpu, "cpu", "proc-stat",
                                        receivedAtMs, _cpuStateStartedAtMs,
                                        _lastCpuSuccessfulAt)
    var ramLifecycle = _normalizeMetric(message.ram, "ram", "proc-meminfo",
                                        receivedAtMs, _ramStateStartedAtMs,
                                        _lastRamSuccessfulAt)
    var cpuMetric = cpuLifecycle.metric
    var ramMetric = ramLifecycle.metric
    _cpuStateStartedAtMs = cpuLifecycle.stateStartedAtMs
    _ramStateStartedAtMs = ramLifecycle.stateStartedAtMs
    _lastCpuSuccessfulAt = cpuLifecycle.lastSuccessfulAt
    _lastRamSuccessfulAt = ramLifecycle.lastSuccessfulAt
    if (message.phase !== "initializing") {
      _expectedSampleAtMs = receivedAtMs + _intervalSeconds * _secondMs
    }
    _failureSince = -1

    if (!_awaitingGpuResume && message.gpuState !== undefined) {
      _captureGpuSessionState(message.gpuState)
    }

    _sequence = message.sequence
    _publishSnapshotChanges({
      schemaVersion: message.schemaVersion,
      generation: message.generation,
      sequence: message.sequence,
      configRevision: message.configRevision,
      phase: _phaseForMetrics(cpuMetric, ramMetric),
      publishedAtMs: message.publishedAtMs,
      cpu: cpuMetric,
      ram: ramMetric,
      gpu: message.gpu,
      selection: _publicGpuSelection(message.selection),
      source: { status: "running" }
    })
  }

  function _handleGpuInventory(message) {
    if (!_helloReceived
        || message.generation !== _generation
        || !Number.isSafeInteger(message.revision)
        || (_gpuInventoryGeneration === _generation
            && message.revision <= _gpuInventory.revision)
        || !Number.isInteger(message.discoveredAtMs)
        || message.discoveredAtMs < 0
        || !Array.isArray(message.devices)
        || message.devices.length > 32
        || (message.gpuState !== undefined
            && !_validGpuSessionState(message.gpuState))) {
      _publishProtocolError()
      return
    }
    var stableIds = ({})
    for (var i = 0; i < message.devices.length; i++) {
      var device = message.devices[i]
      if (!_validGpuDevice(device) || stableIds[device.stableId]) {
        _publishProtocolError()
        return
      }
      stableIds[device.stableId] = true
    }
    if (_awaitingGpuResume) {
      _provisionalGpuInventory = message
      return
    }
    _publishGpuInventory(message)
  }

  function _publishGpuInventory(message) {
    _gpuInventoryGeneration = _generation
    _gpuInventory = _immutable({
      revision: message.revision,
      discoveredAtMs: message.discoveredAtMs,
      devices: message.devices
    })
    if (!_awaitingGpuResume && message.gpuState !== undefined) {
      _captureGpuSessionState(message.gpuState)
    }
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
    if (!command) command = _pendingGpuInventoryRefreshes[message.commandId]
    if (!command) {
      _publishProtocolError()
      return
    }
    if (command.type === "configure") delete _pendingConfigurations[message.commandId]
    else delete _pendingGpuInventoryRefreshes[message.commandId]

    if (message.type === "reject") {
      var rejectCode = message.error === "invalidConfiguration"
        ? message.error : "protocolError"
      if (!command.silent) commandSettled(message.commandId, false, rejectCode)
      if (rejectCode === "protocolError") _publishProtocolError()
      return
    }
    if (command.type === "refreshGpuInventory") {
      if (message.command !== "refreshGpuInventory") {
        commandSettled(message.commandId, false, "protocolError")
        _publishProtocolError()
      } else {
        commandSettled(message.commandId, true, "")
      }
      return
    }
    if (message.configRevision !== command.configRevision
        || message.intervalSeconds !== command.intervalSeconds
        || !_sameGpuSelection(message.gpuSelection, command.gpuSelection)
        || (message.gpuState !== undefined
            && (!_validGpuSessionState(message.gpuState)
                || message.gpuState.selection.mode !== command.gpuSelection.mode))) {
      if (!command.silent) commandSettled(message.commandId, false, "protocolError")
      _publishProtocolError()
      return
    }
    _configRevision = command.configRevision
    _intervalSeconds = command.intervalSeconds
    _gpuSelectionMode = command.gpuSelection.mode
    _gpuStableId = command.gpuSelection.mode === "fixed"
      ? command.gpuSelection.stableId : ""
    var resumeProvedDisappearance = command.silent
      && _awaitingGpuResume
      && _current.selection.status === "selected"
      && message.gpuState !== undefined
      && (message.gpuState.selection.status !== "selected"
          || String(message.gpuState.selection.stableId || "")
             !== String(_current.selection.stableId || ""))
    if (resumeProvedDisappearance && _provisionalGpuInventory !== null) {
      _publishGpuInventory(_provisionalGpuInventory)
    }
    if (message.gpuState !== undefined) _captureGpuSessionState(message.gpuState)
    if (command.silent) {
      _awaitingGpuResume = false
      _provisionalGpuInventory = null
    }
    _expectedSampleAtMs = _nowMs() + _intervalSeconds * _secondMs
    if (!command.silent) commandSettled(message.commandId, true, "")
  }

  function _validMetricState(metric, allowsInitializing) {
    if (!metric
        || (metric.status !== "initializing"
            && metric.status !== "available"
            && metric.status !== "unavailable")) return false
    if (metric.status === "initializing") {
      return allowsInitializing && Number.isInteger(metric.since) && metric.since >= 0
    }
    if (metric.status === "unavailable") {
      return metric.error
        && typeof metric.error.code === "string"
        && typeof metric.error.scope === "string"
        && typeof metric.error.retryability === "string"
        && Number.isInteger(metric.since)
        && metric.since >= 0
    }
    return true
  }

  function _validCpuMetric(metric) {
    if (!_validMetricState(metric, true)) return false
    if (metric.status !== "available") return true
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

  function _validRamMetric(metric) {
    if (!_validMetricState(metric, true)) return false
    if (metric.status !== "available") return true
    return metric.value
      && Number.isInteger(metric.value.percent)
      && metric.value.percent >= 0
      && metric.value.percent <= 100
      && Number.isSafeInteger(metric.value.usedBytes)
      && metric.value.usedBytes >= 0
      && Number.isSafeInteger(metric.value.totalBytes)
      && metric.value.totalBytes > 0
      && metric.value.usedBytes <= metric.value.totalBytes
      && Number.isInteger(metric.sampledAtMs)
      && metric.sampledAtMs >= 0
      && metric.window
      && Number.isInteger(metric.window.actualMs)
      && metric.window.actualMs > 0
      && typeof metric.evidence === "string"
      && typeof metric.path === "string"
  }

  function _validGpuMetric(metric) {
    if (!_validMetricState(metric, false) || metric.status !== "unavailable") return false
    if (typeof metric.error.pathId !== "string" || metric.error.pathId.length === 0
        || typeof metric.error.diagnostic !== "string"
        || metric.error.diagnostic.length === 0) return false
    if (metric.error.stableId !== undefined
        && !_validStableGpuId(metric.error.stableId)) return false
    return metric.retryAt === undefined
      || (Number.isInteger(metric.retryAt) && metric.retryAt >= 0)
  }

  function _sameGpuSelection(left, right) {
    return _validGpuSelectionPolicy(left)
      && _validGpuSelectionPolicy(right)
      && left.mode === right.mode
      && String(left.stableId || "") === String(right.stableId || "")
  }

  function _validGpuSelectionState(selection) {
    if (!selection || typeof selection !== "object") return false
    if (selection.mode === "fixed") {
      return (selection.status === "selected" || selection.status === "missing")
        && _validStableGpuId(selection.stableId)
    }
    if (selection.mode !== "auto" || selection.status === "missing") return false
    if (selection.status === "selected") return _validStableGpuId(selection.stableId)
    return (selection.status === "none" || selection.status === "required")
      && selection.stableId === undefined
  }

  function _sameGpuSelectionState(left, right) {
    return _validGpuSelectionState(left)
      && _validGpuSelectionState(right)
      && left.mode === right.mode
      && left.status === right.status
      && String(left.stableId || "") === String(right.stableId || "")
  }

  function _validGpuSessionState(state) {
    if (!state || typeof state !== "object"
        || !_validGpuSelectionState(state.selection)
        || !Number.isInteger(state.fixedRetryStage)
        || state.fixedRetryStage < 0 || state.fixedRetryStage > 3
        || !Number.isSafeInteger(state.fixedRetryAt)
        || state.fixedRetryAt < -1) return false
    if (state.selection.mode === "auto"
        || state.selection.status === "selected") {
      return state.fixedRetryStage === 0 && state.fixedRetryAt === -1
    }
    if (state.fixedRetryStage === 3) return state.fixedRetryAt === -1
    return state.fixedRetryAt >= 0
  }

  function _validGpuDevice(device) {
    return device
      && typeof device === "object"
      && _validStableGpuId(device.stableId)
      && typeof device.label === "string"
      && device.label.length > 0
      && ["intel", "amd", "nvidia"].indexOf(device.vendor) >= 0
      && typeof device.pciBdf === "string"
      && /^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$/.test(device.pciBdf)
      && ["yes", "no", "unknown"].indexOf(device.displayRelation) >= 0
      && typeof device.selectable === "boolean"
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
