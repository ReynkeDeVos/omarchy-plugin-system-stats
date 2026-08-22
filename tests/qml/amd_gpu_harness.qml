import QtQuick
import Quickshell

GpuSessionHarness {
  expectedCase: String(Quickshell.env("SYSTEM_STATS_AMD_CASE"))
  expectedStatus: String(Quickshell.env("SYSTEM_STATS_AMD_STATUS"))
  expectedError: String(Quickshell.env("SYSTEM_STATS_AMD_ERROR"))
  expectedRetryability: String(Quickshell.env("SYSTEM_STATS_AMD_RETRYABILITY"))
  transientError: String(Quickshell.env("SYSTEM_STATS_AMD_TRANSIENT_ERROR"))
  stableId: String(Quickshell.env("SYSTEM_STATS_AMD_STABLE_ID"))
  pciBdf: String(Quickshell.env("SYSTEM_STATS_AMD_PCI_BDF"))
  expectedPercent: Number(Quickshell.env("SYSTEM_STATS_AMD_PERCENT"))
  expectedPath: String(Quickshell.env("SYSTEM_STATS_AMD_PATH"))
  vendorName: "AMD"
}
