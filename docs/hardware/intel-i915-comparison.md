# Local Intel i915 comparison

Date: 22 August 2026

This check exercises the packaged helper on the development machine without changing permissions or installing tools. It records the current gate result; it does not grant hardware-confirmed evidence.

## Machine

```text
Kernel: 7.1.8-arch1-3
GPU: 0000:00:02.0 Intel Meteor Lake-P [8086:7d45]
Driver: i915
perf_event_paranoid: 2
helper file capabilities: none
```

The i915 PMU exposes six engine-busy aliases on this machine: `bcs0-busy`, `ccs0-busy`, `rcs0-busy`, `vcs0-busy`, `vcs1-busy`, and `vecs0-busy`. It also exposes RC6 residency aliases. The collector accepts only the `*-busy` aliases with unit `ns`, so RC6 cannot enter the utilization result.

## Reproduce the check

Build the helper, confirm the bound device and PMU aliases, then capture one sample:

```bash
make build
lspci -Dnnk -s 0000:00:02.0
cat /proc/sys/kernel/perf_event_paranoid
getcap bin/system-stats-helper
find /sys/bus/event_source/devices/i915/events -maxdepth 1 \
  -type f -name '*-busy' -printf '%f\n' | sort
timeout 4s bin/system-stats-helper | sed -n '1,3p'
```

Compile and run the same direct `perf_event_open` probe used for this report. The
arguments come from the i915 PMU's sysfs ABI rather than hard-coded event numbers:

```bash
cc -std=c17 -O2 -Wall -Wextra -Werror -pedantic \
  tests/native/i915_pmu_probe.c -o /tmp/system-stats-i915-pmu-probe
pmu_root=/sys/bus/event_source/devices/i915
pmu_type=$(cat "$pmu_root/type")
pmu_config=$(sed 's/^config=//' "$pmu_root/events/rcs0-busy")
pmu_cpu=$(sed 's/[-,].*//' "$pmu_root/cpumask")
/tmp/system-stats-i915-pmu-probe "$pmu_type" "$pmu_config" "$pmu_cpu"
```

On a machine where the event is readable, the probe prints the one-second busy
counter delta, elapsed nanoseconds, and their percentage. On this machine it
reproduces `perf_event_open: Permission denied` before sampling.

Count the process directories available to the DRM `fdinfo` fallback:

```bash
seen=0
readable=0
denied=0
for fdinfo_dir in /proc/[0-9]*/fdinfo; do
  ((seen+=1))
  if test -r "$fdinfo_dir" \
      && find "$fdinfo_dir" -maxdepth 1 -type f -print -quit >/dev/null 2>&1; then
    ((readable+=1))
  else
    ((denied+=1))
  fi
done
printf 'proc_fdinfo_dirs=%d readable=%d denied=%d\n' \
  "$seen" "$readable" "$denied"
```

The 22 August run found 372 process `fdinfo` directories: 83 readable and 289 denied. Process churn will change these counts.

## Observed result

The helper selected `pci:0000:00:02.0`, kept CPU and RAM available, and returned this GPU state:

```json
{
  "status": "unavailable",
  "error": {
    "code": "permissionDenied",
    "scope": "gpu",
    "retryability": "retryable",
    "stableId": "pci:0000:00:02.0",
    "pathId": "intel-i915-pmu",
    "diagnostic": "Intel engine counters could not be read with current permissions"
  },
  "evidence": "fixtureTested"
}
```

The direct `perf_event_open` probe for `rcs0-busy` returned `EACCES`. The fallback also lacked system-wide process visibility. Publishing the readable clients would undercount GPU work, so the helper reports the PMU permission failure, leaves the GPU number hidden, and shows an error marker in the Bar.

## Fixture comparison and evidence gate

Run the deterministic i915 and Xe comparison with:

```bash
bash tests/test_intel_gpu.sh
```

The i915 PMU, i915 `fdinfo`, and Xe `fdinfo` fixtures each produce 40% for `0000:00:02.0`. The PMU fixture also exposes an RC6 event worth 100%, which the collector must ignore, and checks that a partly readable engine-event set is rejected. The `fdinfo` inputs include duplicate descriptors for one client, capacity-two engines, and a 100% workload attached to another PCI BDF. The expected 40% results check engine selection, deduplication, capacity handling, and selected-device isolation through `SystemStatsSession`.

The implementation emits `fixtureTested` on both success and failure paths. Change it to `hardwareConfirmed` only after an installed plugin can read the complete Intel counter path and passes the separate CPU, RSS, I/O, process-count, cadence, multi-screen, and long-run release gate.

Kernel references: [DRM client usage stats](https://docs.kernel.org/gpu/drm-usage-stats.html), [Xe DRM usage stats](https://docs.kernel.org/gpu/xe/xe-drm-usage-stats.html), and [PMU sysfs event ABI](https://docs.kernel.org/admin-guide/abi-testing.html#symbols-under-sys-bus-event-source-devices).
