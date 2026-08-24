# Quattro compatibility

Validated target: **Omarchy 4.0.0-1**, using manifest schema 1 and
Quickshell 0.3.0 (revision 28771c7c74b42e20afca0b1b63980cb46515537c).
The packaged helper target is x86-64 Linux.

This is the release boundary for System Stats 0.4.0. On this target, the
official `omarchy plugin validate` command accepts the combined `service` and
`bar-widget` manifest and both QML entry points. Omarchy creates one service in
the long-running shell and one bar-widget instance per screen. Every widget
reads the service through `shell.serviceFor("reynkedevos.system-stats")`, while
its persisted settings come from the one inline bar-layout entry in
`~/.config/omarchy/shell.json`.

The release gate is split into two commands:

```bash
make validate
bash tests/accept_quattro_live.sh
```

The first command is safe for CI and runs the official validator. The live gate
uses the running Omarchy shell and its real screen list. It snapshots the shell
configuration, installs a temporary Git copy, checks placement and shared
lifecycle behavior, then removes the copy and restores the snapshot. It refuses
to replace an existing System Stats installation.

Real system suspend is deliberately opt-in because it changes workstation power
state. Run `bash tests/accept_quattro_live.sh --real-suspend` and follow its two
prompts to add a short and a long suspend/resume cycle to the same helper-count
gate.

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
