import QtQuick
import Quickshell
import "." as SystemStats

ShellRoot {
  id: testRoot

  property bool finished: false
  readonly property string expectedCase: String(Quickshell.env("SYSTEM_STATS_INTEL_CASE"))
  readonly property string expectedStatus: String(Quickshell.env("SYSTEM_STATS_INTEL_STATUS"))
  readonly property string expectedPath: String(Quickshell.env("SYSTEM_STATS_INTEL_PATH"))
  readonly property string expectedError: String(Quickshell.env("SYSTEM_STATS_INTEL_ERROR"))
  readonly property bool expectsRecovery: String(Quickshell.env("SYSTEM_STATS_INTEL_RECOVERY")) === "1"
  readonly property string intelId: "pci:0000:00:02.0"
  property bool sawRetryableError: false

  function fail(message) {
    if (finished) return
    finished = true
    console.error("TEST-FAIL: " + expectedCase + ": " + message)
    Qt.quit()
  }

  function verify(condition, message) {
    if (!condition) fail(message)
    return condition
  }

  function checkSnapshot(snapshot) {
    if (finished) return
    if (expectsRecovery && snapshot.sequence === 1) {
      if (!verify(snapshot.cpu.status === "available"
                  && snapshot.ram.status === "available",
                  "retryable GPU error leaves host metrics available")) return
      if (!verify(snapshot.gpu.status === "unavailable"
                  && snapshot.gpu.error.code === "permissionDenied"
                  && snapshot.gpu.error.retryability === "retryable",
                  "permission failure remains visible while discovery retries")) return
      sawRetryableError = true
      return
    }
    var expectedSequence = expectsRecovery ? 2 : 1
    if (snapshot.sequence !== expectedSequence) return
    if (expectsRecovery
        && !verify(sawRetryableError, "success follows a visible retryable error")) return
    if (!verify(snapshot.cpu.status === "available", "CPU remains available")) return
    if (!verify(snapshot.ram.status === "available", "RAM remains available")) return
    if (!verify(snapshot.selection.status === "selected"
                && snapshot.selection.stableId === intelId,
                "Intel fixture is the selected stable GPU")) return
    if (!verify(snapshot.gpu.status === expectedStatus, "expected Intel GPU status")) return
    if (expectedStatus === "unavailable") {
      if (!verify(snapshot.phase === "degraded", "GPU error degrades only the snapshot")) return
      if (!verify(snapshot.gpu.value === undefined, "GPU error has no display value")) return
      if (!verify(snapshot.gpu.error.code === expectedError,
                  "GPU exposes the expected error code")) return
      if (!verify(snapshot.gpu.error.pathId === expectedPath,
                  "GPU error identifies the failed measurement path")) return
      if (!verify(snapshot.gpu.error.stableId === intelId,
                  "GPU error remains bound to the selected identity")) return
      if (!verify(snapshot.gpu.error.diagnostic.length > 0,
                  "GPU error includes a diagnostic")) return
      if (!verify(snapshot.gpu.since > 0, "GPU error includes a stable start time")) return
      if (!verify(Object.isFrozen(snapshot.gpu), "GPU error immutability")) return
      if (!verify(Object.isFrozen(snapshot.gpu.error), "GPU error detail immutability")) return
      finished = true
      console.log("TEST-PASS: " + expectedCase + " GPU error through SystemStatsSession")
      Qt.quit()
      return
    }
    if (!verify(snapshot.phase === "live", "all three metrics are live")) return
    if (!verify(snapshot.gpu.value.percent === 40,
                "BDF-bound, deduplicated, capacity-aware percentage")) return
    if (!verify(snapshot.gpu.value.device.stableId === intelId,
                "value carries selected stable identity")) return
    if (!verify(snapshot.gpu.value.device.pciBdf === "0000:00:02.0",
                "value carries selected PCI BDF")) return
    if (!verify(snapshot.gpu.value.semantics === "graphicsEngineBusy",
                "value declares true engine semantics")) return
    if (!verify(snapshot.gpu.value.actualWindowMs > 0,
                "value carries an observation window")) return
    if (!verify(snapshot.gpu.path === expectedPath,
                "value identifies the Intel measurement path")) return
    if (!verify(snapshot.gpu.evidence === "fixtureTested",
                "path remains fixture-tested")) return
    if (!verify(Object.isFrozen(snapshot.gpu), "GPU metric immutability")) return
    if (!verify(Object.isFrozen(snapshot.gpu.value), "GPU value immutability")) return
    if (!verify(Object.isFrozen(snapshot.gpu.value.device),
                "GPU device identity immutability")) return

    finished = true
    console.log("TEST-PASS: " + expectedCase + " GPU usage through SystemStatsSession")
    Qt.quit()
  }

  SystemStats.Service { id: session }

  Connections {
    target: session
    function onCurrentChanged() { testRoot.checkSnapshot(session.current) }
  }

  Timer {
    interval: 3000
    running: true
    onTriggered: testRoot.fail("timed out waiting for Intel GPU sample")
  }
}
