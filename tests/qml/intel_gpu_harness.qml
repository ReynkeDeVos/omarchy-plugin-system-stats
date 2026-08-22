import QtQuick
import Quickshell

GpuSessionHarness {
  expectedCase: String(Quickshell.env("SYSTEM_STATS_INTEL_CASE"))
  expectedStatus: String(Quickshell.env("SYSTEM_STATS_INTEL_STATUS"))
  expectedError: String(Quickshell.env("SYSTEM_STATS_INTEL_ERROR"))
  expectedRetryability: ""
  transientError: String(Quickshell.env("SYSTEM_STATS_INTEL_TRANSIENT_ERROR")
                         || "")
  stableId: "pci:0000:00:02.0"
  pciBdf: "0000:00:02.0"
  expectedPercent: 40
  expectedPath: String(Quickshell.env("SYSTEM_STATS_INTEL_PATH"))
  vendorName: "Intel"
  transientMustBeRetryable: true
  verifyFrozen: true
}
