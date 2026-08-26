# Quattro compatibility

Acceptance target: **Omarchy 4.0.1-1**, using manifest schema 1 and
Quickshell 0.3.1 (Arch Linux package; revision field empty).
The gate pins the complete local `quickshell --version` fingerprint,
`Quickshell 0.3.1 (revision , distributed by Arch Linux)`, because this package
does not report a source revision that could honestly be recorded.
The packaged helper candidate targets x86-64 Linux.

Full live acceptance: **pending**.
No successful full `--real-suspend` run has been recorded yet. This document
therefore records the candidate target and its release gate, not a published
compatibility claim.

The official `omarchy plugin validate` command checks the combined `service`
and `bar-widget` manifest and both QML entry points. During the live gate,
Omarchy must create one service in the long-running shell and one bar-widget
instance per screen. A separate, temporary acceptance-probe plugin queries the
Quattro host through Quickshell IPC; production `Service.qml` and
`BarWidget.qml` contain no acceptance interface. The probe confirms that every
widget references the host's one service slot and one immutable Abtastergebnis,
advances through one shared sequence, and receives the same inline settings
from `~/.config/omarchy/shell.json`. A test-only helper guard records any
concurrent helper launch durably instead of relying on process polling.
On this pinned host, `omarchy bar set` persists the inline settings before a normal bar move
but does not reinject them into already-live widget slots. The gate therefore
proves the persisted entry first, reconstructs the slots through the official
`omarchy bar move` path, and only then requires the same injected settings on
every screen. A subsequent plugin reload must retain those values. This matches
the persistence boundary without mistaking stale live slots for a failed write.

The CI-safe validation and the non-power-state-changing live preflight are:

```bash
make validate
bash tests/accept_quattro_live.sh
```

Full Quattro acceptance requires the real suspend mode:

```bash
bash tests/accept_quattro_live.sh --real-suspend
```

The live gate uses the running Omarchy shell and its real screen list. It
records the baseline and each configuration state it produces, installs a
temporary Git copy, checks placement and shared lifecycle behavior, then
removes only entries owned by that acceptance run. A three-way ownership check
preserves unrelated changes made while the gate runs and refuses cleanup if an
acceptance-owned entry changed concurrently. The gate serializes complete runs,
including signal cleanup, and refuses to replace an existing System Stats
installation. Real system suspend is required for acceptance but uses an
explicit flag because it changes workstation power state; the mode prompts for
one short and one long suspend/resume cycle. It observes logind's
`PrepareForSleep(true/false)` pair and compares `CLOCK_BOOTTIME` with
`CLOCK_MONOTONIC`, so time spent waiting at the terminal cannot satisfy the
required actual suspend duration.
Cleanup mutates plugins and shell configuration only after the login session
reports a completed unlock. If the run is interrupted while resume or unlock
is unconfirmed, it preserves a recovery bundle and instructions instead of
reloading the shell under an active lock screen. Recovery requires the run ID
in each checkout's ownership marker and the same configuration ownership check.
Normal exit and TTY recovery execute the same bundled cleanup helper, so those
safety rules cannot drift apart. That helper independently requires the active
Wayland display session, compositor, and shell lock state all to report
unlocked before either cleanup path can mutate a plugin or shell configuration.
From a fresh TTY it discovers the one active Hyprland instance instead of
depending on inherited Wayland environment variables. If `shell.json` did not
exist before the gate, an early failure with no shell-configuration state
preserves that absence. The same applies when an owned checkout was cloned but
configuration was not written yet. After configuration mutations, cleanup
removes the materialized file only when its cleaned value exactly matches the
effective configuration captured before the first mutation; unrelated edits therefore
keep the file. The
original file and effective snapshots are evidence, not files to copy over
later changes. The
bundle is deleted only after helper exit and the absence of its durable overlap
witness are confirmed. The bundle, configuration evidence, and witness live below
`$XDG_STATE_HOME/omarchy-system-stats/acceptance/`, or below
`~/.local/state/omarchy-system-stats/acceptance/` when it is unset, so they
survive a reboot needed to recover from a failed lock screen.

Before entering the real-suspend phase, the gate restarts the unlocked Omarchy
shell before the first suspend. That process boundary discards file-watch
events and reload timers created by the earlier plugin hot-reload check. Once
the replacement shell again proves the complete live contract, the gate records
its process identity and a metadata-and-content fingerprint, including inode and
change time, of the target plugin, acceptance probe, and shell configuration.
The suspend launcher itself checks that process identity before and after
recomputing the fingerprint immediately before invoking `systemctl` on each
cycle. Any shell exit or plugin, probe, or shell configuration rewrite after
that barrier makes the suspend command fail closed instead of risking another
lock-client reload during suspend.

This Quattro gate covers issue #11 only. It does not replace ADR-0001's separate
release requirements: every vendor success path still needs confirmation on
suitable hardware, and the complete two-screen Ressourcenbudget must be
measured before release.

Installation and normal operation do not run install hooks, package managers,
`sudo`, `pkexec`, permission or group changes, `setcap`, `sysctl`, or kernel
parameter writes. The official plugin installer only clones, validates, and
enables the repository. The plugin starts only its packaged unprivileged helper,
which reads the normal kernel and driver interfaces available to the user.

## Limits on other versions

- Omarchy releases before 4.0 are outside this acceptance target. They do not
  provide the exact Quattro manifest, session service, per-screen bar-widget,
  inline settings, and placement contracts exercised by this gate.
- Other Omarchy 4.0 package revisions may work when their manifest schema and
  shell contracts are unchanged, but they are not part of this recorded target.
  Run both release-gate commands before publishing support for one.
- Later Omarchy or Quickshell releases are unvalidated until the official
  validator and the live reload, suspend, disable, and removal checks pass.
- Non-x86-64 systems need a helper built for their architecture; the repository
  currently ships only the x86-64 helper candidate.
