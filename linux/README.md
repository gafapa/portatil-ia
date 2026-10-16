# Portable coding assistants: Linux version

## Folder-only authentication policy

Assistant environments exclude host API keys, tokens, authentication helpers, proxies, and agent sockets. Home directories, cloud profiles, global Git settings, runtime directories, and temporary directories are portable. Sessions with command arguments start inside the assistant folder, rather than the caller's working directory. Windows `-DataDir` must remain inside the assistant folder; linked managed paths are rejected.

Antigravity OAuth sessions are blocked on all systems because they cannot satisfy the current folder-only authentication policy. Only informational commands are available. The launcher and verifier never inspect or move host Keychain/Credential Manager entries. Existing encrypted Antigravity data is preserved. This change does not automatically migrate old host-store backups or pending entries.

These launchers are not an OS sandbox. They control automatic authentication and default storage paths, but cannot prevent an assistant, plugin, tool, browser, or explicitly supplied configuration from reading other files with the current user's permissions. See the project `docs/ISOLATION.md` for the verification scope.

Four AI coding assistants that run from a USB drive (or any folder) on any Linux PC, without installing anything on the computer and without using its accounts or credentials:

| Assistant | Folder | Launcher |
| --- | --- | --- |
| Claude Code | `claude/` | `claude/claude.sh` |
| Codex CLI | `codex/` | `codex/codex.sh` |
| OpenCode | `oc/` | `oc/opencode.sh` |
| Google Antigravity CLI | `antigravity/` | `antigravity/antigravity.sh` |

- **Downloaded from the internet.** The installer fetches every assistant from its official source and checks the published hash before installing it.
- **Self-contained.** Each launcher redirects the assistant's configuration, history, and sessions into the portable folder. Nothing is read from or written to the user's home.
- **Own credentials, encrypted.** Each assistant stores its credentials the first time you sign in inside the portable. They are kept encrypted with one password common to the four assistants and exist in plain text only while an assistant is running. The encryption format is the same as the Windows version's.

This is the Linux version; the project also has Windows and macOS versions (see the project README). The technical design is described in `docs/ARCHITECTURE.md` in the project folder.

## Contents

- [Requirements](#requirements)
- [Folder layout](#folder-layout)
- [Installing](#installing)
- [First start and credentials](#first-start-and-credentials)
- [Daily use](#daily-use)
- [Updating](#updating)
- [Assistant details](#assistant-details)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)

## Requirements

- Linux x64 or ARM64 (glibc or musl; the installer detects musl and downloads the matching builds).
- Python 3.8 or later (`python3`), included in most desktop distributions. If it is missing, the scripts explain how to install it.
- `curl` for downloads (recommended; Python is used when it is missing).
- Internet access to install or update, and for the assistants themselves.
- About 600 MB per architecture on the drive, plus room for sessions. Any file system works; see [Troubleshooting](#troubleshooting) for drives mounted without execute permission.

## Folder layout

```
portatil/linux/
  instalar.sh          installer: install, update, and verify from the internet
  actualizar.sh        updates the portable it is in
  portatil-programa.json   list of scripts and official download sources
  lib/                 python.sh (finds Python), portatil.py (encryption, password),
                       lanzador.py (launcher), instalar.py (installer)
  claude/claude.sh     codex/codex.sh     oc/opencode.sh     antigravity/antigravity.sh
  <assistant>/prog/<arch>/     program, downloaded by the installer (x64, arm64)
  <assistant>/data, config, cache, state, sesiones or workspaces   created on use
  <assistant>/credenciales.enc encrypted credentials
  versiones.json       installed versions and SHA-256 of every program file
  portatil.passcheck   check value of the common password (not a credential)
```

The scripts find their own location at run time, so the mount point does not matter. Keep the whole folder together.

## Installing

From the project folder on a Linux PC (or from a copy of the `linux` folder):

```sh
sh instalar.sh                              # interactive: lists USB drives, asks where
sh instalar.sh /media/$USER/USB/portatil/linux
sh instalar.sh DEST --si                    # no confirmation
sh instalar.sh DEST --forzar                # download everything again
sh instalar.sh DEST --solo-verificar        # verify only, offline
sh instalar.sh DEST --arq todas             # x64 and ARM64 (default: this PC's)
```

The interactive mode lists mounted drives under `/media`, `/run/media`, and `/mnt` (partitions smaller than 1 GB, such as boot partitions, are skipped) and suggests `<drive>/portatil/linux`. The installer queries the latest official versions, shows what it will install or update, and asks for confirmation. Downloads are staged under the installation folder in `.portable-tmp` and removed afterwards.

By default it installs the architecture of the PC it runs on. Use `--arq todas` (or `x64`, `arm64`) to add the other one, for example to use the drive on both kinds of PC; architectures already installed are kept up to date.

| Assistant | Official source | Package | Hash |
| --- | --- | --- | --- |
| Claude Code | `downloads.claude.ai/claude-code-releases`, `stable` channel | `linux-x64` / `linux-arm64` (`-musl` variants on musl) | SHA-256 |
| Codex CLI | GitHub `openai/codex`, latest release | `codex-package-<arch>-unknown-linux-musl.tar.gz` | SHA-256 (GitHub digest) |
| OpenCode | GitHub `sst/opencode`, latest release | `opencode-linux-x64-baseline.tar.gz` / `opencode-linux-arm64.tar.gz` (`-musl` variants on musl) | SHA-256 (GitHub digest) |
| Antigravity CLI | Updater manifest used by Google's installer | `linux_amd64` / `linux_arm64` | SHA-512 |

**Alternative: copy and update.** The `linux` folder of the project contains no programs and no credentials, so it can be copied to the drive as is. Then run `sh actualizar.sh` in the copy once.

## First start and credentials

The portable never uses the credentials of the PC it runs on. A new portable has none; each assistant stores its own the first time you sign in:

1. Start the launcher (`sh claude/claude.sh`). It says that the portable has no credentials yet.
2. Sign in: `/login` in Claude Code, `codex login` (or when Codex asks), `/connect` in OpenCode, Antigravity OAuth is blocked.
3. Close the assistant normally. The launcher asks for the portable password, encrypts the credentials into `credenciales.enc`, and removes the plain-text files.

**One password for the four assistants**, recorded as a check value in `portatil.passcheck`: the first assistant that saves credentials asks for a new password twice; the others ask for the same one and reject any other.

If the password prompt is cancelled or the assistant does not close normally, the plain-text credentials are kept and encrypted on the next start.

## Daily use

```sh
sh /media/$USER/USB/portatil/linux/claude/claude.sh              # workspace menu
sh /media/$USER/USB/portatil/linux/claude/claude.sh --espacio proyecto
sh /media/$USER/USB/portatil/linux/claude/claude.sh --version    # other arguments go to the assistant
```

Without arguments the launcher asks for the password (once credentials exist) and shows the workspace menu: choose a workspace, create one, or press Enter to cancel. Workspaces are normal folders (`sesiones/<name>`, or `workspaces/<name>` for Codex).

On drives mounted with execute permission the scripts can also be run directly (`./claude/claude.sh`).

Always close the assistants normally before removing the drive: credentials are encrypted when the assistant exits. Ctrl+C and closing the terminal reach the assistant, and the launcher still encrypts afterwards.

For automation, the password can be passed in `PORTATIL_PASSWORD`; the launcher removes it before starting the assistant.

## Updating

On the drive, run `sh actualizar.sh`. It downloads only the assistants (and architectures) that have a newer official version or missing files, and verifies the result. It accepts `--si`, `--forzar`, `--solo-verificar`, and `--arq`. It never touches sessions, credentials, or the password. To update the scripts themselves, run `instalar.sh` from the project folder with the drive as the destination.

## Assistant details

| Detail | Claude Code | Codex CLI | OpenCode | Antigravity |
| --- | --- | --- | --- | --- |
| Program | `prog/<arch>/claude` | `prog/<arch>/bin/codex` + `codex-path`, `codex-resources` | `prog/<arch>/opencode` | `prog/<arch>/antigravity` |
| State redirected with | `CLAUDE_CONFIG_DIR` | `CODEX_HOME` | `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, `XDG_STATE_HOME` | `HOME` and the `XDG_*` variables |
| Credentials while running | `data/claude/.credentials.json` | `data/codex/auth.json` | `data/opencode/auth.json`, `mcp-auth.json` | OAuth blocked |
| Sign in | `/login` | `codex login` | `/connect` | Browser (Google) |

**Codex CLI.** The launcher sets `cli_auth_credentials_store = "file"` in `data/codex/config.toml`, so Codex always keeps its login in the portable and never in the system keyring.

**Antigravity CLI.** OAuth sessions are blocked. Version and help commands use a portable profile and portable temporary directories. A separately configured portable Gemini API mode is not yet implemented.

## Troubleshooting

| Situation | What to do |
| --- | --- |
| "Hace falta Python 3.8 o posterior" | Install `python3` with the distribution's package manager. |
| "Permission denied" when running a `.sh` | Run it with `sh`: `sh claude/claude.sh`. |
| The drive does not allow running programs (FAT mounted with `showexec`, or `noexec`) | The launcher stops without copying programs to the PC. Use an executable mount and a supported file system. |
| "Falta el programa ... para este equipo" | The drive has no program for this PC's architecture: run `sh actualizar.sh --arq todas`, or `--arq x64`/`arm64`. |
| Forgot the password | It cannot be recovered. Delete every `credenciales.enc` and `portatil.passcheck`, then sign in again in each assistant. |
| Sign in with another account | Delete that assistant's `credenciales.enc`, start it, and sign in. |
| Warning about credentials left unencrypted | Start that assistant and close it normally, or run it with `--solo-cifrar`. |
| The installer reports FALLO | Run it again, with `--forzar` if a file was altered. |

## Security notes

- Credentials exist in plain text only while an assistant is running, with mode 0600 where the file system supports permissions. exFAT and FAT have no permissions: do not leave an assistant open on a shared PC.
- Always close the assistants normally before removing the drive.
- The `credenciales.enc` files are only as strong as the password; use a long one.
- Revoke any provider API key that was ever exposed in a terminal or a conversation.
- `versiones.json` detects corruption and accidental changes of the program files, not deliberate tampering by someone who can write to the drive; reinstall with `--forzar` from a trusted PC in that case.
