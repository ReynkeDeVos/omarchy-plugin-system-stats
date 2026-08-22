function verifyHostMetrics(root, snapshot) {
  return root.verify(snapshot.cpu.status === "available", "CPU remains available")
    && root.verify(snapshot.ram.status === "available", "RAM remains available")
}

function verifySelection(root, snapshot, stableId, vendorName) {
  return root.verify(snapshot.selection.status === "selected"
                     && snapshot.selection.stableId === stableId,
                     vendorName + " fixture is the selected stable GPU")
}

function verifyTransientError(root, snapshot, errorCode) {
  return verifyHostMetrics(root, snapshot)
    && root.verify(snapshot.gpu.status === "unavailable"
                   && snapshot.gpu.error.code === errorCode,
                   "transient GPU failure remains visible before recovery")
}

function verifyError(root, snapshot, errorCode, retryability, stableId,
                     path, verifyFrozen) {
  if (!root.verify(snapshot.phase === "degraded",
                   "GPU error degrades only the snapshot")) return false
  if (!root.verify(snapshot.gpu.value === undefined,
                   "GPU error has no display value")) return false
  if (!root.verify(snapshot.gpu.error.code === errorCode,
                   "GPU exposes the expected error code")) return false
  if (retryability !== ""
      && !root.verify(snapshot.gpu.error.retryability === retryability,
                      "GPU error exposes the expected retryability")) return false
  if (!root.verify(snapshot.gpu.error.pathId === path,
                   "GPU error identifies the failed measurement path")) return false
  if (!root.verify(snapshot.gpu.error.stableId === stableId,
                   "GPU error remains bound to the selected identity")) return false
  if (!root.verify(snapshot.gpu.error.diagnostic.length > 0,
                   "GPU error includes a diagnostic")) return false
  if (!root.verify(snapshot.gpu.since > 0,
                   "GPU error includes a stable start time")) return false
  if (verifyFrozen
      && !root.verify(Object.isFrozen(snapshot.gpu)
                      && Object.isFrozen(snapshot.gpu.error),
                      "GPU error is immutable")) return false
  return true
}

function verifyValue(root, snapshot, percent, stableId, pciBdf, path,
                     verifyFrozen) {
  if (!root.verify(snapshot.phase === "live",
                   "all three metrics are live")) return false
  if (!root.verify(snapshot.gpu.value.percent === percent,
                   "selected GPU percentage reaches the session")) return false
  if (!root.verify(snapshot.gpu.value.device.stableId === stableId,
                   "value carries selected stable identity")) return false
  if (!root.verify(snapshot.gpu.value.device.pciBdf === pciBdf,
                   "value carries selected PCI BDF")) return false
  if (!root.verify(snapshot.gpu.value.semantics === "graphicsEngineBusy",
                   "value declares true engine semantics")) return false
  if (!root.verify(snapshot.gpu.value.actualWindowMs > 0,
                   "value carries an observation window")) return false
  if (!root.verify(snapshot.gpu.path === path,
                   "value identifies the GPU measurement path")) return false
  if (!root.verify(snapshot.gpu.evidence === "fixtureTested",
                   "path remains fixture-tested")) return false
  if (verifyFrozen
      && !root.verify(Object.isFrozen(snapshot.gpu)
                      && Object.isFrozen(snapshot.gpu.value)
                      && Object.isFrozen(snapshot.gpu.value.device),
                      "GPU value is immutable")) return false
  return true
}
