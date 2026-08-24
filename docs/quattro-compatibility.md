# Quattro compatibility

Validated target: **Omarchy 4.0.0-1**, using manifest schema 1 and
Quickshell 0.3.0 (revision 28771c7c74b42e20afca0b1b63980cb46515537c).
The packaged helper target is x86-64 Linux.

This is the validated Quattro compatibility target for System Stats 0.4.0. On
this target, the official `omarchy plugin validate` command accepts the combined
`service` and `bar-widget` manifest and both QML entry points. Omarchy creates
one service in the long-running shell and one bar-widget instance per screen.
The live gate queries the widgets through Quickshell IPC to confirm that they
reference one service object, one immutable Abtastergebnis, one advancing
sequence, and the same inline settings from `~/.config/omarchy/shell.json`.

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
snapshots the shell configuration, installs a temporary Git copy, checks
placement and shared lifecycle behavior, then removes the copy and restores the
snapshot. It refuses to replace an existing System Stats installation. Real
system suspend is required for acceptance but uses an explicit flag because it
changes workstation power state; the mode prompts for one short and one long
suspend/resume cycle.

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

- Omarchy releases before 4.0 are unsupported. They do not provide the exact
  Quattro manifest, session service, per-screen bar-widget, inline settings, and
  placement contracts validated here.
- Other Omarchy 4.0 package revisions may work when their manifest schema and
  shell contracts are unchanged, but they are not part of this recorded target.
  Run both release-gate commands before publishing support for one.
- Later Omarchy or Quickshell releases are unvalidated until the official
  validator and the live reload, suspend, disable, and removal checks pass.
- Non-x86-64 systems need a helper built for their architecture; the repository
  currently ships only the validated x86-64 helper.
