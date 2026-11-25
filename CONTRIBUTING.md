# Contributing

Thanks for helping. A few ground rules keep this small project tidy.

## Workflow

- `main` is protected. Work on a branch and open a **pull request**; direct pushes and force pushes to `main` are blocked.
- The `check` workflow must pass. Run it locally first:

  ```bash
  scripts/check.sh
  ```
- Pull requests are squash-merged, so keep the PR title a good commit message.

## Tests

- `node tests/model.test.js` covers `Model.js`: validation (including attempts to smuggle options into the `ssh` command line), parsing, states, error mapping and drop detection. `scripts/check.sh` runs it.
- `tests/e2e-local.sh` runs the shell scripts against **real `systemd --user` units** with a fake `ssh` (`tests/fake-ssh.sh`): start, loopback-only binding, restart, stop, failures with readable reasons, and a port taken by another program. It needs a systemd user session, so CI does not run it. Run it before you change `scripts/tunnel-ctl.sh` or `scripts/tunnel-status.sh`.

- `tests/e2e-real-ssh.sh` uses **real ssh**: a private `sshd` on `127.0.0.1:22222` run as you with temporary keys, a passphrase-protected key, a private `ssh-agent` and a fake database. It proves the host key check, login through the agent, and data flowing through the forward. Nothing is installed or enabled and everything is removed on exit. It needs `sshd`, `ssh-agent`, `python3` and a systemd user session, so CI does not run it.

## Trying your changes

Clone the repo straight into the plugin folder. Omarchy reloads plugin code when you save a file.

```bash
git clone https://github.com/<you>/omarchy-conduit-tunnel.git ~/.config/omarchy/plugins/conduit.tunnel
omarchy plugin enable conduit.tunnel
omarchy plugin validate ~/.config/omarchy/plugins/conduit.tunnel
```

If a change does not show up, run `omarchy-shell shell rescanPlugins`, or `omarchy restart shell`.

## The shared UI kit

The `Conduit*.qml` components are a verified copy of the kit in [`omarchy-conduit-vpn`](https://github.com/andriar/omarchy-conduit-vpn). Do not edit them here: change them there (see its DESIGN.md), then run `scripts/sync-ui.sh` in this repo. `check` fails if a component no longer matches `ui.lock`.

## Translations

Every user-visible string lives in `i18n/<language>.json`; `en.json` is the reference.

1. Copy `i18n/en.json` to `i18n/<code>.json` (an Omarchy language code such as `de`, `pt-BR` or `id`).
2. Translate the values. Keep the keys and the `%1`, `%2` placeholders.
3. Run `scripts/check.sh`. It fails on invalid JSON, keys that are not in `en.json`, and keys used in code that `en.json` does not define.

A string missing from your file falls back to English, so a partial translation is fine.

## Please never commit

Your `tunnels.json`, `~/.ssh/config`, keys, logs, or any real hostname or address. Examples and screenshots use made-up names (`example`, `invalid`). `scripts/check.sh` rejects the obvious cases, but you are the last line of defence.

## Style

Follow DESIGN.md in `omarchy-conduit-vpn`: quiet UI, theme tokens only, one primary action per view, destructive actions kept apart.
