import QtQuick
import Quickshell
import "." as SystemStats
import "gpu_harness_assertions.js" as GpuAssertions

ShellRoot {
  id: testRoot

  required property string expectedCase
  required property string expectedStatus
  required property string expectedError
  required property string expectedRetryability
  required property string transientError
  required property string stableId
  required property string pciBdf
  required property int expectedPercent
  required property string expectedPath
  required property string vendorName
  property bool transientMustBeRetryable: false
  property bool verifyFrozen: false
  property bool finished: false
  property bool sawTransientError: false
  readonly property bool expectsRecovery: transientError !== ""

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
      if (!GpuAssertions.verifyTransientError(testRoot, snapshot,
                                              transientError)) return
      if (transientMustBeRetryable
          && !verify(snapshot.gpu.error.retryability === "retryable",
                     "transient GPU failure is retryable")) return
      sawTransientError = true
      return
    }

    var expectedSequence = expectsRecovery ? 2 : 1
    if (snapshot.sequence !== expectedSequence) return
    if (expectsRecovery
        && !verify(sawTransientError,
                   "success follows a visible transient error")) return
    if (!GpuAssertions.verifyHostMetrics(testRoot, snapshot)) return
    if (!GpuAssertions.verifySelection(testRoot, snapshot, stableId,
                                       vendorName)) return
    if (!verify(snapshot.gpu.status === expectedStatus,
                "expected " + vendorName + " GPU status")) return

    if (expectedStatus === "unavailable") {
      if (!GpuAssertions.verifyError(testRoot, snapshot, expectedError,
                                     expectedRetryability, stableId,
                                     expectedPath, verifyFrozen)) return
      finished = true
      console.log("TEST-PASS: " + expectedCase
                  + " GPU error through SystemStatsSession")
      Qt.quit()
      return
    }

    if (!GpuAssertions.verifyValue(testRoot, snapshot, expectedPercent,
                                   stableId, pciBdf, expectedPath,
                                   verifyFrozen)) return
    finished = true
    console.log("TEST-PASS: " + expectedCase
                + " GPU usage through SystemStatsSession")
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
    onTriggered: testRoot.fail("timed out waiting for GPU sample")
  }
}
