# System Stats

System Stats is an Omarchy Quattro plugin that puts one compact, shared CPU metric in every screen's bar. A session-wide service owns one long-lived native helper, so adding a screen does not add another sampler or timer.

This first vertical slice intentionally shows CPU only. RAM and GPU are unavailable in the published snapshot and stay hidden in the bar rather than appearing as invented zero values.
Their transitional `dependencyMissing` state is intentionally limited to this CPU-only slice.

## Install

The plugin package includes its x86-64 Linux helper. Installation does not compile code, install packages, invoke `sudo`, or change system permissions.

```bash
omarchy plugin add https://github.com/ReynkeDeVos/omarchy-plugin-system-stats.git --enable
```

The manifest defaults the widget to the right bar section. It can be moved later with Omarchy's bar tools.

## How CPU usage is measured

The helper reads the aggregate `cpu` row from `/proc/stat` at two consecutive two-second schedule boundaries. Active time is `user + nice + system + irq + softirq + steal`; inactive time is `idle + iowait`. The displayed value is the active share of the complete interval, rounded to the nearest integer with halves rounded up. It is neither smoothed nor sampled through a shorter nested window.

The CPU path is marked fixture-tested. Hardware-confirmed evidence is reserved for the separate real-hardware and resource-budget release gate.

## Development

Rebuild the packaged helper and run every check with:

```bash
make build
make test
```

Tests exercise CPU behavior through the public `SystemStatsSession.current` state exposed by `Service.qml`. Fixture reads shorten the interval but use the same helper and parsing path as production. The widget smoke test instantiates two callers against one service, then inspects the live process tree to verify that only one single-threaded helper and scheduler exist.

## License

MIT. See [LICENSE](LICENSE).
