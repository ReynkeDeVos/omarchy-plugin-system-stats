# System Stats

System Stats is an Omarchy Quattro plugin that puts compact, shared CPU and RAM metrics in each screen's bar. A session-wide service owns one long-lived native helper, so adding a screen does not add another sampler or timer.

RAM appears as a whole percentage by default. Omarchy's bar settings can switch it to used/total IEC GiB with one decimal place; the change reuses the current sample and keeps the widget width stable.

Click the widget to inspect the GPU inventory and choose a device. Device names come from the NVIDIA driver or udev's hardware database when available. Auto selects the sole GPU or the only GPU connected to a display. Systems with several plausible GPUs ask you to choose. The plugin saves a fixed choice as a PCI BDF or NVIDIA UUID through Omarchy settings, so device enumeration order cannot change it. GPU utilization stays hidden until a vendor measurement path can report a real value.

## Install

The plugin package includes its x86-64 Linux helper. Installation does not compile code, install packages, invoke `sudo`, or change system permissions.

```bash
omarchy plugin add https://github.com/ReynkeDeVos/omarchy-plugin-system-stats.git --enable
```

The manifest defaults the widget to the right bar section. It can be moved later with Omarchy's bar tools.

## How usage is measured

The helper reads the aggregate `cpu` row from `/proc/stat` at two consecutive schedule boundaries. The interval defaults to two seconds and `SystemStatsSession.configure(...)` accepts whole values from two through ten seconds without restarting the helper. An interval change discards the old CPU basis, publishes initialization, and waits for one complete new window.

Active time is `user + nice + system + irq + softirq + steal`; inactive time is `idle + iowait`. The displayed value is the active share of the complete interval, rounded to the nearest integer with halves rounded up. It is neither smoothed nor sampled through a shorter nested window.

At the same schedule boundary, the helper reads `/proc/meminfo`. RAM usage is exclusively `MemTotal - MemAvailable`; the percentage is that result divided by `MemTotal`. Swap, VRAM, `MemFree`, and process RSS are not used. Missing fields, zero total memory, malformed sizes, or `MemAvailable` larger than `MemTotal` make only the RAM metric unavailable.

## Failure handling

An expected failed sample becomes unavailable immediately. Every successful CPU or RAM value has an absolute four-second freshness limit, so intervals from five through ten seconds intentionally have a short unavailable gap before their next sample.

The session validates the helper protocol and supervises the process. A crash restarts with `1, 2, 4, 8, 16, 30, 30 …` second backoff, reset after 60 seconds of stable operation. A helper that misses its scheduled result by two seconds is terminated before a replacement can start. The shared source state exposes the error, last successful sample, and next restart time.

The helper rebuilds the GPU inventory at session start, when you open the picker, and after it proves that the selected device disappeared. It does not scan for GPUs on the metric sampling cadence or after a settings change. A missing fixed GPU triggers an immediate search, then retries after 30 seconds, 5 minutes, and 30 minutes. After those attempts, the helper waits for you to reopen the picker or start a new session. Automatic selection and the fixed-device retry stage survive a supervised helper restart. CPU and RAM continue sampling while GPU selection or measurement is unavailable.

The CPU path is marked fixture-tested. Hardware-confirmed evidence is reserved for the separate real-hardware and resource-budget release gate.

## Development

Rebuild the packaged helper and run every check with:

```bash
make build
make test
```

Tests exercise CPU, RAM, and GPU selection through the public `SystemStatsSession` interface exposed by `Service.qml`. Fixture reads shorten the interval but use the same helper and parsing path as production. GPU fixtures cover integrated, discrete, and hybrid layouts; production-style udev naming; hotplug; fixed-device retries; helper restarts; and restoration across sessions. Scripted process tests cover malformed protocol traffic, stale values, crashes, hangs, and backoff without waiting real minutes. The widget smoke test verifies both RAM formats, stable reserved width, picker persistence, and two callers sharing one single-threaded helper and scheduler.

## License

MIT. See [LICENSE](LICENSE).
