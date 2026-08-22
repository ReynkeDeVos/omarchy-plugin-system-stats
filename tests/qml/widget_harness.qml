import QtQuick
import Quickshell
import "plugin" as SystemStats

ShellRoot {
  id: testRoot

  property bool finished: false
  property bool ready: false
  property real screenAWidth: 0
  property real screenBWidth: 0
  property int inventoryRevisionBeforeOpen: 0
  property bool pickerOpened: false
  readonly property string fixedGpuId: "nvidia:GPU-22222222-2222-2222-2222-222222222222"

  function checkGiBFormats() {
    if (!verify(screenA.snapshotSequence === 1, "screen A format switch reuses snapshot")) return
    if (!verify(screenB.snapshotSequence === 1, "screen B format switch reuses snapshot")) return
    if (!verify(screenA.ramDisplayValue === "10.0/16.0", "screen A RAM GiB value")) return
    if (!verify(screenB.ramDisplayValue === "10.0/16.0", "screen B RAM GiB value")) return
    if (!verify(screenA.ramDisplayUnit === " GiB", "screen A RAM GiB unit")) return
    if (!verify(screenB.ramDisplayUnit === " GiB", "screen B RAM GiB unit")) return
    if (!verify(screenA.implicitWidth === screenAWidth, "screen A width remains reserved")) return
    if (!verify(screenB.implicitWidth === screenBWidth, "screen B width remains reserved")) return

    screenA.settings = ({ ramDisplayFormat: "invalid" })
    Qt.callLater(checkInvalidFormat)
  }

  function checkInvalidFormat() {
    if (!verify(screenA.ramDisplayFormat === "percent", "invalid RAM format falls back")) return
    if (!verify(screenA.ramDisplayValue === "63", "fallback RAM percentage")) return
    if (!verify(screenA.implicitWidth === screenAWidth, "fallback keeps reserved width")) return

    inventoryRevisionBeforeOpen = session.gpuInventory.revision
    screenA.open()
    if (!verify(screenA.opened, "left-click action opens detail panel")) return
    if (!verify(!screenB.opened, "panel remains local to one screen")) return
    pickerOpened = true
    checkPicker()
  }

  function checkPicker() {
    if (!pickerOpened || session.gpuInventory.revision <= inventoryRevisionBeforeOpen) return
    if (!verify(screenA.gpuOptions.length === 3, "picker contains Auto and every device")) return
    if (!verify(screenA.gpuOptions[0].value === "auto", "Auto is first picker option")) return
    if (!verify(screenA.gpuOptions[1].label.indexOf(screenA.gpuOptions[1].value) !== -1,
                "device option shows stable identity")) return
    if (!verify(screenA.selectedGpuDevice !== null
                && screenA.selectedGpuDevice.stableId === "pci:0000:00:02.0",
                "Auto exposes the active GPU details")) return
    screenA.selectGpu("pci:0000:ff:00.0")
    if (!verify(fakeBarA.persistenceCount === 0,
                "stale picker identity is not persisted")) return
    screenA.selectGpu(fixedGpuId)
    pickerOpened = false
  }

  function checkPersistedSelection(snapshot) {
    if (snapshot.selection.mode !== "fixed" || snapshot.selection.status !== "selected") return
    if (!verify(snapshot.selection.stableId === fixedGpuId, "picker configures fixed identity")) return
    if (!verify(fakeBarA.persistenceCount === 1, "picker writes through Omarchy settings once")) return
    if (!verify(fakeBarA.persistedGpuSelection.mode === "fixed", "fixed mode persisted")) return
    if (!verify(fakeBarA.persistedGpuSelection.stableId === fixedGpuId,
                "stable identity persisted")) return
    if (!verify(fakeBarA.persistedGpuSelection.card === undefined
                && fakeBarA.persistedGpuSelection.index === undefined,
                "unstable indices are not persisted")) return
    ready = true
    console.log("TEST-READY: two widgets share one session")
    finishTimer.start()
  }

  function fail(message) {
    if (finished) return
    finished = true
    console.error("TEST-FAIL: " + message)
    Qt.quit()
  }

  function verify(condition, message) {
    if (!condition) fail(message)
    return condition
  }

  function checkWidgets(snapshot) {
    if (finished || ready || snapshot.sequence !== 1) return
    if (!verify(fakeBarA !== fakeBarB, "screens have distinct bar callers")) return
    if (!verify(screenA.bar === fakeBarA, "screen A owns bar A")) return
    if (!verify(screenB.bar === fakeBarB, "screen B owns bar B")) return
    if (!verify(screenA.session === session, "screen A uses shared session")) return
    if (!verify(screenB.session === session, "screen B uses shared session")) return
    if (!verify(screenA.snapshotSequence === 1, "screen A sequence")) return
    if (!verify(screenB.snapshotSequence === 1, "screen B sequence")) return
    if (!verify(screenA.cpuVisible && screenB.cpuVisible, "CPU metrics visible")) return
    if (!verify(screenA.ramVisible && screenB.ramVisible, "RAM metrics visible")) return
    if (!verify(screenA.gpuVisible && screenB.gpuVisible, "GPU metrics visible")) return
    if (!verify(!screenA.gpuErrorVisible && !screenB.gpuErrorVisible,
                "available GPU metrics have no error marker")) return
    if (!verify(screenA.displayValue === "37", "screen A CPU value")) return
    if (!verify(screenB.displayValue === "37", "screen B CPU value")) return
    if (!verify(screenA.ramDisplayFormat === "percent", "screen A default RAM format")) return
    if (!verify(screenB.ramDisplayFormat === "percent", "screen B default RAM format")) return
    if (!verify(screenA.ramDisplayValue === "63", "screen A RAM percentage")) return
    if (!verify(screenB.ramDisplayValue === "63", "screen B RAM percentage")) return
    if (!verify(screenA.ramDisplayUnit === "%", "screen A RAM percentage unit")) return
    if (!verify(screenB.ramDisplayUnit === "%", "screen B RAM percentage unit")) return
    if (!verify(screenA.gpuDisplayValue === "40", "screen A GPU percentage")) return
    if (!verify(screenB.gpuDisplayValue === "40", "screen B GPU percentage")) return
    if (!verify(screenA.gpuStatusSummary() === "40% graphics engine busy",
                "detail panel summarizes the available value")) return
    if (!verify(screenA.gpuMeasurementPath() === "i915 DRM fdinfo",
                "detail panel names the measurement path")) return
    if (!verify(screenA.gpuEvidenceSummary() === "Fixture-tested",
                "detail panel names the evidence status")) return
    if (!verify(screenA.Accessible.name.indexOf("RAM 63 Prozent") !== -1,
                "RAM percentage is accessible")) return
    if (!verify(screenA.Accessible.name.indexOf("GPU 40 Prozent") !== -1,
                "GPU percentage is accessible")) return

    screenAWidth = screenA.implicitWidth
    screenBWidth = screenB.implicitWidth
    screenA.settings = ({ ramDisplayFormat: "gib" })
    screenB.settings = ({ ramDisplayFormat: "gib" })
    Qt.callLater(checkGiBFormats)
  }

  SystemStats.Service {
    id: session
  }

  Connections {
    target: session
    function onCurrentChanged() {
      testRoot.checkWidgets(session.current)
      testRoot.checkPersistedSelection(session.current)
    }
    function onGpuInventoryChanged() { testRoot.checkPicker() }
  }

  FakeBar {
    id: fakeBarA
    session: session
  }

  FakeBar {
    id: fakeBarB
    session: session
  }

  SystemStats.BarWidget {
    id: screenA
    bar: fakeBarA
  }

  SystemStats.BarWidget {
    id: screenB
    bar: fakeBarB
  }

  Timer {
    id: finishTimer

    interval: 1000
    onTriggered: {
      testRoot.finished = true
      console.log("TEST-PASS: two widgets share one session")
      Qt.quit()
    }
  }

  Timer {
    interval: 2000
    running: true
    onTriggered: testRoot.fail("timed out waiting for shared widget state")
  }

  Component.onCompleted: {
    if (!verify(screenA.initializing && screenB.initializing, "initialization display")) return
    if (!verify(!screenA.cpuVisible && !screenB.cpuVisible, "CPU hidden while initializing")) return
    if (!verify(!screenA.ramVisible && !screenB.ramVisible, "RAM hidden while initializing")) return
    if (!verify(!screenA.gpuVisible && !screenB.gpuVisible, "GPU hidden while initializing")) return
  }
}
