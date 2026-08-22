import QtQuick
import Quickshell

GpuSessionHarness {
  expectedCase: String(Quickshell.env("SYSTEM_STATS_NVIDIA_CASE"))
  expectedStatus: String(Quickshell.env("SYSTEM_STATS_NVIDIA_STATUS"))
  expectedError: String(Quickshell.env("SYSTEM_STATS_NVIDIA_ERROR"))
  expectedRetryability: String(Quickshell.env("SYSTEM_STATS_NVIDIA_RETRYABILITY"))
  transientError: ""
  stableId: String(Quickshell.env("SYSTEM_STATS_NVIDIA_STABLE_ID"))
  pciBdf: String(Quickshell.env("SYSTEM_STATS_NVIDIA_PCI_BDF"))
  expectedPercent: Number(Quickshell.env("SYSTEM_STATS_NVIDIA_PERCENT"))
  expectedPath: "nvidia-nvml"
  vendorName: "Nvidia"
  reopenAfterError: expectedCase === "hung-reopen"
  reopenAfterSuccess: expectedCase === "shutdown-hangs"
}
