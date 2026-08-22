import QtQuick
import Quickshell
import Quickshell.Io
import "." as SystemStats

ShellRoot {
  id: testRoot

  readonly property string caseName: String(Quickshell.env("SYSTEM_STATS_GPU_CASE"))
  readonly property string inventoryPath: String(Quickshell.env("SYSTEM_STATS_GPU_INVENTORY_FILE"))
  readonly property string presencePath: String(Quickshell.env("SYSTEM_STATS_GPU_PRESENCE_FILE"))
  readonly property string intelId: "pci:0000:00:02.0"
  readonly property string amdId: "pci:0000:03:00.0"
  readonly property string nvidiaId: "nvidia:GPU-22222222-2222-2222-2222-222222222222"
  readonly property var fixedCase: caseName === "fixed-amd" ? ({
    targetId: amdId,
    targetLine: amdId + "\tAMD Radeon RX Fixture\tamd\t0000:03:00.0\tno\t1\n",
    vendor: "AMD",
    expectedError: "deviceMissing",
    otherId: intelId,
    otherLine: intelId + "\tIntel Meteor Lake-P Graphics\tintel\t0000:00:02.0\tyes\t1\n"
  }) : caseName === "fixed-intel" ? ({
    targetId: intelId,
    targetLine: intelId + "\tIntel Meteor Lake-P Graphics\tintel\t0000:00:02.0\tno\t1\n",
    vendor: "Intel",
    expectedError: "noTrueEnginePath",
    otherId: nvidiaId,
    otherLine: nvidiaId + "\tNVIDIA GeForce RTX Fixture\tnvidia\t0000:01:00.0\tyes\t1\n"
  }) : ({
    targetId: nvidiaId,
    targetLine: nvidiaId + "\tNVIDIA GeForce RTX Fixture\tnvidia\t0000:01:00.0\tno\t1\n",
    vendor: "Nvidia",
    expectedError: "dependencyMissing",
    otherId: intelId,
    otherLine: intelId + "\tIntel Meteor Lake-P Graphics\tintel\t0000:00:02.0\tyes\t1\n"
  })
  property bool finished: false
  property int stage: 0
  property int stableRevision: 0
  property int refreshCommandId: 0
  property int configureCommandId: 0
  property bool refreshAccepted: false
  property bool configureAccepted: false
  property double firstGeneration: 0

  ElapsedTimer { id: elapsed }

  FileView {
    id: inventoryFile
    path: testRoot.inventoryPath
    atomicWrites: true
    blockWrites: true
    printErrors: true
  }

  FileView {
    id: presenceFile
    path: testRoot.presencePath
    atomicWrites: true
    blockWrites: true
    printErrors: true
  }

  function fail(message) {
    if (finished) return
    finished = true
    console.error("TEST-FAIL: " + caseName + ": " + message)
    Qt.quit()
  }

  function verify(condition, message) {
    if (!condition) fail(message)
    return condition
  }

  function device(stableId) {
    for (var i = 0; i < session.gpuInventory.devices.length; i++) {
      var candidate = session.gpuInventory.devices[i]
      if (candidate.stableId === stableId) return candidate
    }
    return null
  }

  function finish(message) {
    finished = true
    console.log("TEST-PASS: " + message)
    Qt.quit()
  }

  function checkDeviceContract(candidate, vendor, relation) {
    return verify(candidate !== null, "inventory contains stable device")
      && verify(candidate.label.length > 0, "device has understandable label")
      && verify(candidate.vendor === vendor, "device vendor")
      && verify(candidate.pciBdf.indexOf("0000:") === 0, "device PCI BDF")
      && verify(candidate.displayRelation === relation, "device display relation")
      && verify(candidate.selectable === true, "device is selectable")
      && verify(candidate.card === undefined && candidate.index === undefined,
                "unstable indices are not public")
  }

  function checkIndependentMetrics(snapshot) {
    return verify(snapshot.cpu.status === "available", "CPU remains available")
      && verify(snapshot.ram.status === "available", "RAM remains available")
      && verify(snapshot.gpu.status === "unavailable", "GPU stays honestly unavailable")
  }

  function checkSingle(snapshot) {
    if (snapshot.sequence < 3 || session.gpuInventory.revision < 1) return
    if (!checkIndependentMetrics(snapshot)) return
    if (!verify(session.gpuInventory.devices.length === 1, "single-device inventory")) return
    if (!checkDeviceContract(device(intelId), "intel", "yes")) return
    if (!verify(snapshot.selection.mode === "auto", "auto mode")) return
    if (!verify(snapshot.selection.status === "selected", "single GPU is selected")) return
    if (!verify(snapshot.selection.stableId === intelId, "single stable identity selected")) return
    if (!verify(snapshot.gpu.error.code === "noTrueEnginePath", "missing measurement is explicit")) return
    if (!verify(snapshot.gpu.error.stableId === intelId, "GPU error names selected identity")) return
    if (!verify(snapshot.gpu.error.pathId === "intel-measurement",
                "selected Intel GPU identifies its measurement path")) return
    if (!verify(snapshot.gpu.error.diagnostic.length > 0, "GPU error has diagnostic")) return
    if (!verify(Object.isFrozen(session.gpuInventory), "inventory immutability")) return
    if (!verify(Object.isFrozen(session.gpuInventory.devices), "device list immutability")) return
    stableRevision = session.gpuInventory.revision
    settleTimer.start()
  }

  function checkUniqueDisplay(snapshot) {
    if (snapshot.sequence < 1 || session.gpuInventory.revision < 1) return
    if (!checkIndependentMetrics(snapshot)) return
    if (!verify(session.gpuInventory.devices.length === 2, "hybrid inventory")) return
    if (!checkDeviceContract(device(intelId), "intel", "yes")) return
    if (!checkDeviceContract(device(nvidiaId), "nvidia", "no")) return
    if (!verify(snapshot.selection.status === "selected", "display GPU selected")) return
    if (!verify(snapshot.selection.stableId === intelId, "unique display GPU identity")) return
    finish("unique display GPU is selected through SystemStatsSession")
  }

  function checkSingleNvidia(snapshot) {
    if (snapshot.sequence < 1 || session.gpuInventory.revision < 1) return
    if (!checkIndependentMetrics(snapshot)) return
    if (!verify(session.gpuInventory.devices.length === 1, "single NVIDIA inventory")) return
    if (!checkDeviceContract(device(nvidiaId), "nvidia", "yes")) return
    if (!verify(snapshot.selection.status === "selected", "single NVIDIA GPU is selected")) return
    if (!verify(snapshot.selection.stableId === nvidiaId, "NVIDIA UUID is the stable identity")) return
    finish("single NVIDIA UUID is selected through SystemStatsSession")
  }

  function checkLinuxLabel(snapshot) {
    if (snapshot.sequence < 1 || session.gpuInventory.revision < 1) return
    if (!checkIndependentMetrics(snapshot)) return
    var candidate = device(intelId)
    if (!checkDeviceContract(candidate, "intel", "yes")) return
    if (!verify(candidate.label === "Meteor Lake-P Integrated Graphics Controller",
                "production discovery uses the udev hardware name")) return
    finish("production discovery exposes an understandable GPU name through SystemStatsSession")
  }

  function checkNoGpu(snapshot) {
    if (snapshot.sequence < 1 || session.gpuInventory.revision < 1) return
    if (!checkIndependentMetrics(snapshot)) return
    if (!verify(session.gpuInventory.devices.length === 0, "empty GPU inventory")) return
    if (!verify(snapshot.selection.status === "none", "empty system has no selection")) return
    if (!verify(snapshot.gpu.error.code === "deviceMissing", "empty system reports missing GPU")) return
    if (!verify(snapshot.gpu.error.pathId === "gpu-inventory", "empty system identifies inventory path")) return
    finish("missing GPU leaves CPU and RAM live through SystemStatsSession")
  }

  function checkAmbiguous(snapshot) {
    if (snapshot.sequence < 1 || session.gpuInventory.revision < 1) return
    if (!checkIndependentMetrics(snapshot)) return
    if (!verify(snapshot.selection.mode === "auto", "ambiguous system stays in auto")) return
    if (!verify(snapshot.selection.status === "required", "ambiguous system requires selection")) return
    if (!verify(snapshot.selection.stableId === undefined, "ambiguous system has no fallback identity")) return
    if (!verify(snapshot.gpu.error.code === "selectionRequired", "GPU explains required selection")) return
    if (!verify(snapshot.gpu.error.pathId === "gpu-selection", "selection error identifies selection path")) return
    finish("ambiguous multi-GPU system requires selection through SystemStatsSession")
  }

  function checkHotplug(snapshot) {
    if (session.gpuInventory.revision < 1 || snapshot.sequence < 1) return

    if (stage === 0) {
      if (snapshot.selection.status !== "selected" || snapshot.selection.stableId !== intelId) return
      stage = 1
      stableRevision = session.gpuInventory.revision
      settleTimer.start()
      return
    }

    if (stage === 2 && session.gpuInventory.revision >= stableRevision + 1
        && refreshAccepted) {
      if (!verify(session.gpuInventory.devices.length === 2, "new device appears after explicit refresh")) return
      if (!verify(snapshot.selection.stableId === intelId, "new device does not change auto selection")) return
      stage = 3
      inventoryFile.setText("" +
        nvidiaId + "\tNVIDIA GeForce RTX Fixture\tnvidia\t0000:01:00.0\tyes\t1\n")
      presenceFile.setText(nvidiaId + "\n")
      return
    }

    if (stage === 3 && session.gpuInventory.revision >= stableRevision + 2
        && snapshot.selection.stableId === nvidiaId) {
      if (!verify(snapshot.selection.status === "selected", "auto recovers after proven disappearance")) return
      if (!verify(snapshot.selection.stableId === nvidiaId, "remaining GPU selected after disappearance")) return
      if (!verify(session.gpuInventory.devices.length === 1, "inventory rebuilt after disappearance")) return
      finish("auto selection stays stable and reconciles proven hotplug through SystemStatsSession")
    }
  }

  function checkFixed(snapshot) {
    if (stage === 0 && snapshot.generation > 0
        && session.gpuInventory.revision >= 1) {
      stage = 1
      stableRevision = session.gpuInventory.revision
      session.configure({
        configRevision: 1,
        intervalSeconds: 2,
        gpuSelection: { mode: "fixed", stableId: fixedCase.targetId }
      })
      return
    }
    if (stage === 1 && session.gpuInventory.revision === stableRevision + 1
        && snapshot.configRevision === 1 && snapshot.selection.status === "missing") {
      if (!checkIndependentMetrics(snapshot)) return
      if (!verify(snapshot.selection.mode === "fixed", "fixed mode retained")) return
      if (!verify(snapshot.selection.stableId === fixedCase.targetId, "missing fixed identity retained")) return
      if (!verify(snapshot.gpu.error.code === "deviceMissing", "fixed absence is explicit")) return
      if (!verify(snapshot.gpu.error.stableId === fixedCase.targetId, "missing error keeps fixed identity")) return
      if (!verify(snapshot.gpu.error.pathId === "gpu-inventory", "missing fixed GPU identifies inventory path")) return
      if (!verify(device(fixedCase.otherId) !== null, "other GPU remains inventoried")) return
      stableRevision = session.gpuInventory.revision
      stage = 2
      return
    }
    if (stage === 2 && session.gpuInventory.revision >= stableRevision + 3
        && snapshot.gpu.retryAt === undefined) {
      if (!verify(snapshot.selection.status === "missing", "fixed selection does not fall back")) return
      stableRevision = session.gpuInventory.revision
      stage = 3
      pauseTimer.start()
      return
    }
    if (stage === 4 && session.gpuInventory.revision >= stableRevision + 1
        && snapshot.selection.status === "selected") {
      if (!verify(snapshot.selection.stableId === fixedCase.targetId, "returning fixed identity restored")) return
      if (!verify(snapshot.gpu.error.code === fixedCase.expectedError,
                  "returned GPU reports its vendor measurement failure")) return
      finish("fixed " + fixedCase.vendor
             + " GPU retries, pauses, and returns through SystemStatsSession")
    }
  }

  function checkFixedImmediate(snapshot) {
    if (stage === 0 && snapshot.sequence >= 1
        && session.gpuInventory.revision >= 1
        && snapshot.selection.stableId === intelId) {
      stage = 1
      stableRevision = session.gpuInventory.revision
      inventoryFile.setText("" +
        intelId + "\tIntel Meteor Lake-P Graphics\tintel\t0000:00:02.0\tyes\t1\n" +
        nvidiaId + "\tNVIDIA GeForce RTX Fixture\tnvidia\t0000:01:00.0\tno\t1\n")
      presenceFile.setText(intelId + "\n" + nvidiaId + "\n")
      configureCommandId = session.configure({
        configRevision: 1,
        intervalSeconds: 2,
        gpuSelection: { mode: "fixed", stableId: nvidiaId }
      })
      return
    }
    if (stage === 1 && configureAccepted && snapshot.configRevision === 1
        && snapshot.selection.status === "selected") {
      if (!checkIndependentMetrics(snapshot)) return
      if (!verify(snapshot.selection.mode === "fixed", "fixed mode is applied")) return
      if (!verify(snapshot.selection.stableId === nvidiaId,
                  "the immediate search finds the requested stable identity")) return
      finish("fixed selection performs its immediate GPU search")
    }
  }

  function checkSwitchToAuto(snapshot) {
    if (stage === 0 && snapshot.selection.status === "selected"
        && snapshot.selection.stableId === intelId) {
      stage = 1
      session.configure({
        configRevision: 1,
        intervalSeconds: 2,
        gpuSelection: { mode: "fixed", stableId: nvidiaId }
      })
      return
    }
    if (stage === 1 && snapshot.configRevision === 1
        && snapshot.selection.mode === "fixed"
        && snapshot.selection.stableId === nvidiaId) {
      stage = 2
      session.configure({
        configRevision: 2,
        intervalSeconds: 2,
        gpuSelection: { mode: "auto" }
      })
      return
    }
    if (stage === 2 && snapshot.configRevision === 2
        && snapshot.selection.mode === "auto") {
      if (!verify(snapshot.selection.status === "selected", "Auto selects after fixed mode")) return
      if (!verify(snapshot.selection.stableId === intelId,
                  "Auto reapplies the unique-display rule")) return
      finish("switching back to Auto reapplies selection rules through SystemStatsSession")
    }
  }

  function checkAutoRestart(snapshot) {
    if (stage === 0 && snapshot.sequence >= 1
        && snapshot.selection.status === "selected"
        && snapshot.selection.stableId === intelId) {
      firstGeneration = snapshot.generation
      stableRevision = session.gpuInventory.revision
      stage = 1
      inventoryFile.setText("" +
        intelId + "\tIntel Meteor Lake-P Graphics\tintel\t0000:00:02.0\tyes\t1\n" +
        nvidiaId + "\tNVIDIA GeForce RTX Fixture\tnvidia\t0000:01:00.0\tyes\t1\n")
      presenceFile.setText(intelId + "\n" + nvidiaId + "\n")
      return
    }
    if (stage === 1 && snapshot.generation !== firstGeneration
        && snapshot.sequence >= 1) {
      if (!verify(session.gpuInventory.revision === stableRevision
                  && session.gpuInventory.devices.length === 1,
                  "provisional helper inventory stays outside session state")) return
      if (!verify(snapshot.selection.mode === "auto", "Auto policy survives helper restart")) return
      if (!verify(snapshot.selection.status === "selected", "Auto remains selected after helper restart")) return
      if (!verify(snapshot.selection.stableId === intelId,
                  "helper restart does not re-run an ambiguous Auto choice")) return
      stage = 2
      refreshCommandId = session.refreshGpuInventory()
      return
    }
    if (stage === 2 && refreshAccepted
        && session.gpuInventory.devices.length === 2) {
      if (!verify(snapshot.selection.stableId === intelId,
                  "picker refresh keeps the session-stable Auto choice")) return
      finish("Auto selection survives a helper restart through SystemStatsSession")
    }
  }

  function checkFixedRestart(snapshot) {
    if (stage === 0 && snapshot.generation > 0
        && session.gpuInventory.revision >= 1) {
      stage = 1
      session.configure({
        configRevision: 1,
        intervalSeconds: 2,
        gpuSelection: { mode: "fixed", stableId: nvidiaId }
      })
      return
    }
    if (stage === 1 && snapshot.configRevision === 1
        && snapshot.selection.status === "missing"
        && session.gpuInventory.revision >= 4
        && snapshot.gpu.retryAt === undefined) {
      firstGeneration = snapshot.generation
      stage = 2
      return
    }
    if (stage === 2 && snapshot.generation !== firstGeneration
        && snapshot.sequence >= 1) {
      if (!verify(snapshot.selection.mode === "fixed", "fixed policy survives helper restart")) return
      if (!verify(snapshot.selection.stableId === nvidiaId, "fixed identity survives helper restart")) return
      if (!verify(snapshot.selection.status === "missing", "fixed GPU stays missing without fallback")) return
      if (!verify(snapshot.gpu.retryAt === undefined, "paused fixed search survives helper restart")) return
      stableRevision = session.gpuInventory.revision
      stage = 3
      restartPauseTimer.start()
      return
    }
    if (stage === 4 && snapshot.selection.status === "selected") {
      if (!verify(snapshot.selection.stableId === nvidiaId,
                  "picker restores the same fixed GPU after restart")) return
      finish("fixed retry pause survives a helper restart through SystemStatsSession")
    }
  }

  function checkRequiredRestart(snapshot) {
    if (stage === 0 && snapshot.sequence >= 1
        && snapshot.selection.status === "required") {
      firstGeneration = snapshot.generation
      stableRevision = session.gpuInventory.revision
      stage = 1
      inventoryFile.setText("" +
        nvidiaId + "\tNVIDIA GeForce RTX Fixture\tnvidia\t0000:01:00.0\tyes\t1\n")
      presenceFile.setText(nvidiaId + "\n")
      return
    }
    if (stage === 1 && snapshot.generation !== firstGeneration
        && snapshot.sequence >= 1) {
      if (!verify(snapshot.selection.status === "required",
                  "ambiguous Auto state survives helper restart")) return
      if (!verify(snapshot.selection.stableId === undefined,
                  "helper restart does not invent an Auto fallback")) return
      if (!verify(session.gpuInventory.revision === stableRevision
                  && session.gpuInventory.devices.length === 2,
                  "provisional helper inventory stays outside session state")) return
      stage = 2
      refreshCommandId = session.refreshGpuInventory()
      return
    }
    if (stage === 2 && refreshAccepted
        && session.gpuInventory.devices.length === 1
        && snapshot.selection.status === "selected") {
      if (!verify(snapshot.selection.stableId === nvidiaId,
                  "picker refresh selects the remaining GPU")) return
      finish("required Auto state survives helper restart through SystemStatsSession")
    }
  }

  function checkSelectedDisappearsRestart(snapshot) {
    if (stage === 0 && snapshot.sequence >= 1
        && snapshot.selection.status === "selected"
        && snapshot.selection.stableId === intelId) {
      firstGeneration = snapshot.generation
      stage = 1
      inventoryFile.setText("" +
        nvidiaId + "\tNVIDIA GeForce RTX Fixture\tnvidia\t0000:01:00.0\tyes\t1\n")
      presenceFile.setText(nvidiaId + "\n")
      return
    }
    if (stage === 1 && snapshot.generation !== firstGeneration
        && snapshot.sequence >= 1) {
      if (!verify(snapshot.selection.status === "selected",
                  "Auto recovers when the selected GPU disappeared")) return
      if (!verify(snapshot.selection.stableId === nvidiaId,
                  "Auto selects the remaining GPU after disappearance")) return
      if (!verify(session.gpuInventory.devices.length === 1
                  && device(nvidiaId) !== null,
                  "proven disappearance publishes the replacement inventory")) return
      finish("selected GPU disappearance during helper restart updates the inventory")
    }
  }

  function checkSnapshot(snapshot) {
    if (finished) return
    if (caseName === "single") checkSingle(snapshot)
    else if (caseName === "single-nvidia") checkSingleNvidia(snapshot)
    else if (caseName === "linux-label") checkLinuxLabel(snapshot)
    else if (caseName === "none") checkNoGpu(snapshot)
    else if (caseName === "unique-display") checkUniqueDisplay(snapshot)
    else if (caseName === "ambiguous") checkAmbiguous(snapshot)
    else if (caseName === "hotplug") checkHotplug(snapshot)
    else if (caseName === "fixed" || caseName === "fixed-amd"
             || caseName === "fixed-intel") checkFixed(snapshot)
    else if (caseName === "fixed-immediate") checkFixedImmediate(snapshot)
    else if (caseName === "switch-auto") checkSwitchToAuto(snapshot)
    else if (caseName === "auto-restart") checkAutoRestart(snapshot)
    else if (caseName === "fixed-restart") checkFixedRestart(snapshot)
    else if (caseName === "required-restart") checkRequiredRestart(snapshot)
    else if (caseName === "selected-disappears-restart") checkSelectedDisappearsRestart(snapshot)
    else fail("unknown case")
  }

  SystemStats.Service { id: session }

  Connections {
    target: session
    function onCurrentChanged() { testRoot.checkSnapshot(session.current) }
    function onGpuInventoryChanged() { testRoot.checkSnapshot(session.current) }
    function onCommandSettled(commandId, accepted, errorCode) {
      if (commandId === configureCommandId) {
        configureAccepted = accepted && errorCode === ""
        if (!verify(configureAccepted, "fixed configuration is accepted")) return
        if (!verify(session.gpuInventory.revision === stableRevision + 1,
                    "missing fixed selection triggers an immediate inventory search")) return
        testRoot.checkSnapshot(session.current)
        return
      }
      if (commandId === refreshCommandId) {
        refreshAccepted = accepted && errorCode === ""
        testRoot.checkSnapshot(session.current)
      }
    }
  }

  Timer {
    id: settleTimer
    interval: 60
    onTriggered: {
      if (caseName === "single") {
        if (!verify(session.gpuInventory.revision === stableRevision,
                    "normal samples do not rebuild inventory")) return
        finish("single GPU inventory stays outside the sample cadence")
        return
      }
      if (caseName === "hotplug") {
        if (!verify(session.gpuInventory.revision === stableRevision,
                    "normal samples do not discover added devices")) return
        inventoryFile.setText("" +
          intelId + "\tIntel Meteor Lake-P Graphics\tintel\t0000:00:02.0\tyes\t1\n" +
          nvidiaId + "\tNVIDIA GeForce RTX Fixture\tnvidia\t0000:01:00.0\tno\t1\n")
        presenceFile.setText(intelId + "\n" + nvidiaId + "\n")
        stage = 2
        refreshCommandId = session.refreshGpuInventory()
      }
    }
  }

  Timer {
    id: pauseTimer
    interval: 250
    onTriggered: {
      if (!verify(session.gpuInventory.revision === stableRevision,
                  "automatic fixed-device search remains paused")) return
      inventoryFile.setText(fixedCase.otherLine + fixedCase.targetLine)
      presenceFile.setText(fixedCase.otherId + "\n" + fixedCase.targetId + "\n")
      stage = 4
      refreshCommandId = session.refreshGpuInventory()
    }
  }

  Timer {
    id: restartPauseTimer
    interval: 250
    onTriggered: {
      if (!verify(session.gpuInventory.revision === stableRevision,
                  "helper restart does not reset the paused search")) return
      inventoryFile.setText("" +
        intelId + "\tIntel Meteor Lake-P Graphics\tintel\t0000:00:02.0\tyes\t1\n" +
        nvidiaId + "\tNVIDIA GeForce RTX Fixture\tnvidia\t0000:01:00.0\tno\t1\n")
      presenceFile.setText(intelId + "\n" + nvidiaId + "\n")
      stage = 4
      refreshCommandId = session.refreshGpuInventory()
    }
  }

  Timer {
    interval: 12000
    running: true
    onTriggered: fail("timed out")
  }
}
