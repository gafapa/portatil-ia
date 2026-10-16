# Portable coding assistants: macOS version

## Folder-only authentication policy

Assistant environments exclude host API keys, tokens, authentication helpers, proxies, and agent sockets. Home directories, cloud profiles, global Git settings, runtime directories, and temporary directories are portable. Sessions with command arguments start inside the assistant folder, rather than the caller's working directory. Windows `-DataDir` must remain inside the assistant folder; linked managed paths are rejected.

Antigravity OAuth sessions are blocked on all systems because they cannot satisfy the current folder-only authentication policy. Only informational commands are available. The launcher and verifier never inspect or move host Keychain/Credential Manager entries. Existing encrypted Antigravity data is preserved. This change does not automatically migrate old host-store backups or pending entries.

These launchers are not an OS sandbox. They control automatic authentication and default storage paths, but cannot prevent an assistant, plugin, tool, browser, or explicitly supplied configuration from reading other files with the current user's permissions. See the project `docs/ISOLATION.md` for the verification scope.

Four AI coding assistants that run from a USB drive (or any folder) on any Mac, without installing anything on the computer and without using its accounts or credentials:

| Assistant | Folder | Launcher |
| --- | --- | --- |
| Claude Code | `claude/` | `claude/claude.sh` |
| Codex CLI | `codex/` | `codex/codex.sh` |
| OpenCode | `oc/` | `oc/opencode.sh` |
| Google Antigravity CLI | `antigravity/` | `antigravity/antigravity.sh` |

- **Downloaded from the internet.** The installer fetches every assistant from its official source and checks the published hash before installing it.
- **Self-contained.** Each launcher redirects the assistant's configuration, history, and sessions into the portable folder.
- **Own credentials, encrypted.** Each assistant stores its credentials the first time you sign in inside the portable. They are kept encrypted with one password common to the four assistants. The encryption format is the same as the Windows and Linux versions'.
- **Mac Keychain.** Claude Code and Antigravity keep their login in the Mac's Keychain, which would leave it on the Mac. The portable avoids that; see [Credentials on macOS](#credentials-on-macos).

This is the macOS version; the project also has Windows and Linux versions (see the project README). The technical design is described in `docs/ARCHITECTURE.md` in the project folder.

## Contents

- [Requirements](#requirements)
- [Folder layout](#folder-layout)
- [Installing](#installing)
- [First start and credentials](#first-start-and-credentials)
- [Credentials on macOS](#credentials-on-macos)
- [Daily use](#daily-use)
- [Updating](#updating)
- [Assistant details](#assistant-details)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)

## Requirements

- macOS on Apple silicon (arm64) or Intel (x64).
- Python 3.8 or later. It comes with the Command Line Tools (`xcode-select --install`), already installed on Macs that use git. If it is missing, the scripts say how to install it.
- Internet access to install or update, and for the assistants themselves.
- About 550 MB per architecture on the drive, plus room for sessions.

## Folder layout

```
portatil/macos/
  instalar.sh          installer: install, update, and verify from the internet
  actualizar.sh        updates the portable it is in
  portatil-programa.json   list of scripts and official download sources
  lib/                 python.sh (finds Python), portatil.py (encryption, password),
                       lanzador.py (launcher), instalar.py (installer)
  claude/claude.sh     codex/codex.sh     oc/opencode.sh     antigravity/antigravity.sh
  <assistant>/prog/<arch>/     program, downloaded by the installer (arm64, x64)
  <assistant>/data, config, cache, state, sesiones or workspaces   created on use
  <assistant>/credenciales.enc encrypted credentials
  versiones.json       installed versions and SHA-256 of every program file
  portatil.passcheck   check value of the common password (not a credential)
```

## Installing

From the project folder on a Mac (or from a copy of the `macos` folder), in Terminal:

```sh
sh instalar.sh                              # interactive: lists drives in /Volumes, asks where
sh instalar.sh /Volumes/USB/portatil/macos
sh instalar.sh DEST --si                    # no confirmation
sh instalar.sh DEST --forzar                # download everything again
sh instalar.sh DEST --solo-verificar        # verify only, offline
sh instalar.sh DEST --arq todas             # Apple silicon and Intel (default: this Mac's)
```

The interactive mode lists the volumes in `/Volumes` and suggests `<volume>/portatil/macos`. By default it installs the architecture of the Mac it runs on. With `--arq todas` the drive works on both kinds of Mac; a Mac with Apple silicon can also run the Intel build through Rosetta 2 when only that one is installed.

| Assistant | Official source | Package | Hash |
| --- | --- | --- | --- |
| Claude Code | `downloads.claude.ai/claude-code-releases`, `stable` channel | `darwin-arm64` / `darwin-x64` | SHA-256 |
| Codex CLI | GitHub `openai/codex`, latest release | `codex-package-<arch>-apple-darwin.tar.gz` | SHA-256 (GitHub digest) |
| OpenCode | GitHub `sst/opencode`, latest release | `opencode-darwin-arm64.zip` / `opencode-darwin-x64-baseline.zip` | SHA-256 (GitHub digest) |
| Antigravity CLI | Updater manifest used by Google's installer | `darwin_arm64` / `darwin_amd64` | SHA-512 |

The installer removes the quarantine attribute from the downloaded programs so Gatekeeper does not block them.

**Alternative: copy and update.** The `macos` folder of the project contains no programs and no credentials, so it can be copied to the drive as is. Then run `sh actualizar.sh` in the copy once.

## First start and credentials

A new portable has no credentials; each assistant stores its own the first time you use it. When it exits, the launcher asks for the portable password and encrypts the credentials into `credenciales.enc`.

**One password for the four assistants**, recorded as a check value in `portatil.passcheck`: the first assistant that saves credentials asks for a new password twice; the others ask for the same one and reject any other.

## Credentials on macOS

**Claude Code: login token.** Claude Code stores `/login` in the Mac's Keychain and has no option to use a file instead, so that login would stay on the Mac. The portable uses instead a one-year token created by Claude Code itself (`claude setup-token`):

1. The first time, `claude.sh` explains this and opens `claude setup-token`. Authorize in the browser.
2. Copy the token it shows (`sk-ant-...`) and paste it when the launcher asks (it is not echoed).
3. The launcher saves it encrypted and passes it to Claude Code in `CLAUDE_CODE_OAUTH_TOKEN` on every start.

Limitation, as documented by Anthropic: with this token Claude Code can use the models, but the claude.ai connectors and Remote Control do not work. Do not run `/login` inside the portable: that login would go to the Mac's Keychain. To replace the token, run `sh claude/claude.sh --configurar-token`. Host environment tokens are ignored; paste the token interactively during portable setup.

**Antigravity CLI.** OAuth sessions are blocked. Version and help commands use a portable profile and portable temporary directories. A separately configured portable Gemini API mode is not yet implemented.

**Codex and OpenCode** keep their credentials in files in the portable (the launcher sets `cli_auth_credentials_store = "file"` for Codex).

## Daily use

```sh
sh /Volumes/USB/portatil/macos/claude/claude.sh              # workspace menu
sh /Volumes/USB/portatil/macos/claude/claude.sh --espacio proyecto
sh /Volumes/USB/portatil/macos/codex/codex.sh --version      # other arguments go to the assistant
```

Without arguments the launcher asks for the password (once credentials exist) and shows the workspace menu. Always close the assistants normally before ejecting the drive: credentials are encrypted when the assistant exits.

## Updating

On the drive, run `sh actualizar.sh`. It downloads only what has a newer official version or missing files, and verifies the result. It never touches sessions, credentials, or the password. To update the scripts themselves, run `instalar.sh` from the project folder with the drive as the destination.

## Assistant details

| Detail | Claude Code | Codex CLI | OpenCode | Antigravity |
| --- | --- | --- | --- | --- |
| Program | `prog/<arch>/claude` | `prog/<arch>/bin/codex` + `codex-path`, `codex-resources` | `prog/<arch>/opencode` | `prog/<arch>/antigravity` |
| State redirected with | `CLAUDE_CONFIG_DIR` | `CODEX_HOME` | `XDG_*` variables | `HOME` and the `XDG_*` variables |
| Credentials | token (`CLAUDE_CODE_OAUTH_TOKEN`) | `data/codex/auth.json` | `data/opencode/auth.json`, `mcp-auth.json` | OAuth blocked |

## Troubleshooting

| Situation | What to do |
| --- | --- |
| "Hace falta Python 3.8 o posterior" | Run `xcode-select --install`. |
| Gatekeeper blocks a program | Run `sh actualizar.sh --forzar` (it removes the quarantine attribute), or `xattr -dr com.apple.quarantine /Volumes/USB/portatil/macos`. |
| "Falta el programa ... para este equipo" | Install this Mac's architecture: `sh actualizar.sh --arq todas`. |
| Claude Code asks to log in | The token expired or was revoked: `sh claude/claude.sh --configurar-token`. |
| Forgot the password | It cannot be recovered. Delete every `credenciales.enc` and `portatil.passcheck`, then set up each assistant again. |
| Warning about credentials left unencrypted | Start that assistant and close it normally. |

## Security notes

- Supported assistant credential files are decrypted only for the session and encrypted on normal exit. Credential protection failures must be recovered before removing the drive. NTFS/POSIX permissions restrict access; exFAT and FAT have no file permissions.
- Always close the assistants normally before ejecting the drive.
- The `credenciales.enc` files are only as strong as the password; use a long one.
- The Claude token gives access to your subscription for a year: if the drive is lost, revoke it from your claude.ai account settings.
- `versiones.json` detects corruption and accidental changes of the program files, not deliberate tampering by someone who can write to the drive.
