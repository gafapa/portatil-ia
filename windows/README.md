# Portable coding assistants: Windows version

## Folder-only authentication policy

Assistant environments exclude host API keys, tokens, authentication helpers, proxies, and agent sockets. Home directories, cloud profiles, global Git settings, runtime directories, and temporary directories are portable. Sessions with command arguments start inside the assistant folder, rather than the caller's working directory. Windows `-DataDir` must remain inside the assistant folder; linked managed paths are rejected.

Antigravity OAuth sessions are blocked on all systems because they cannot satisfy the current folder-only authentication policy. Only informational commands are available. The launcher and verifier never inspect or move host Keychain/Credential Manager entries. Existing encrypted Antigravity data is preserved. This change does not automatically migrate old host-store backups or pending entries.

These launchers are not an OS sandbox. They control automatic authentication and default storage paths, but cannot prevent an assistant, plugin, tool, browser, or explicitly supplied configuration from reading other files with the current user's permissions. See the project `docs/ISOLATION.md` for the verification scope.

Four AI coding assistants that run from a USB drive (or any folder) on any Windows PC, without installing anything on the computer and without using its accounts or credentials:

| Assistant | Folder | Launcher |
| --- | --- | --- |
| Claude Code | `claude\` | `claude\claude.cmd` |
| Codex CLI | `codex\` | `codex\codex.cmd` |
| OpenCode | `oc\` | `oc\opencode.cmd` |
| Google Antigravity CLI | `antigravity\` | `antigravity\antigravity.cmd` |

- **Downloaded from the internet.** The installer fetches every assistant from its official source and checks the published hash before installing it.
- **Portable defaults.** Each launcher redirects the assistant's standard configuration, history, temporary files, and sessions into the portable folder. Restricting direct host access by the assistant also requires OS isolation; see the folder-only authentication policy below.
- **Own credentials, encrypted.** Each assistant stores its credentials the first time you sign in inside the portable. They are kept encrypted with one password common to the four assistants and exist in plain text only while an assistant is running.
- **Verifiable.** Installing, updating, and `-SoloVerificar` check file integrity, that the programs start, and the state of the credentials.

This is the Windows version. The project also has Linux and macOS versions (folders `linux` and `macos` next to this one); see the project README. The technical design (file formats, launcher lifecycle, installer internals, how to add an assistant) is described in `docs/ARCHITECTURE.md`, in the project folder on the PC (it is not copied to the drives).

## Contents

- [Requirements](#requirements)
- [Folder layout](#folder-layout)
- [Installing on a USB drive](#installing-on-a-usb-drive)
- [First start and credentials](#first-start-and-credentials)
- [Daily use](#daily-use)
- [Updating](#updating)
- [Verification](#verification)
- [Assistant details](#assistant-details)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)

## Requirements

- Windows 10 or Windows 11 (x64, or ARM64 through x64 emulation).
- Windows PowerShell 5.1, included with Windows. PowerShell 7 is used automatically when it is installed.
- Internet access to install or update, and for the assistants themselves.
- About 1.2 GB free on the drive for the programs, plus room for sessions. Any file system works (NTFS, exFAT, FAT32).

## Folder layout

The `windows` folder of the project (for example `C:\portatil-ia\windows` after cloning or downloading it) contains **only scripts**. The installer copies them to the destination and downloads the programs next to them.

```
portatil\windows\
  instalar.cmd / instalar.ps1   installer: install, update, and verify from the internet
  actualizar.cmd                updates the portable it is in (instalar.cmd on its own folder)
  portable-crypto.ps1           credential encryption and common password, shared by the launchers
  portable-keyring.ps1          moves Antigravity's Credential Manager entries in and out
  portatil-programa.psd1        list of scripts and official download sources
  README.md
  claude\       claude.cmd, claude.ps1         + bin\ (downloaded)       + data\, sesiones\ (created on use)
  codex\        codex.cmd, codex.ps1           + bin\, codex-path\, codex-resources\, codex-package.json (downloaded)
                                               + data\, workspaces\ (created on use)
  oc\           opencode.cmd, opencode.ps1     + bin\ (downloaded)       + data\, config\, cache\, sesiones\
  antigravity\  antigravity.cmd, antigravity.ps1 + bin\ (downloaded)     + data\, config\, cache\, sesiones\

  Created by the installer and the launchers in an installed portable:
  versiones.json                installed versions and SHA-256 of every program file
  portatil.passcheck            check value of the common password (not a credential)
```

Keep the whole folder together; the launchers need `portable-crypto.ps1` and `portable-keyring.ps1` from the parent folder. The launchers find their own location at run time, so the drive letter and the folder path do not matter.

## Installing on a USB drive

1. Connect the USB drive.
2. Run `C:\portatil-ia\windows\instalar.cmd` (double-click works).
3. Choose the drive from the list (or type another folder) and confirm the installation folder, `<drive>:\portatil\windows` by default, so the Linux and macOS versions can sit next to it on the same drive.
4. The installer shows the latest official versions and what it will do. Confirm to download and install.
5. When the verification ends with **Todo correcto**, the portable is ready.

```cmd
rem interactive
C:\portatil-ia\windows\instalar.cmd
rem install or update E:\portatil\windows (asks before)
C:\portatil-ia\windows\instalar.cmd E:\portatil\windows
rem without confirmation / download everything again / verify only, offline
C:\portatil-ia\windows\instalar.cmd E:\portatil\windows -Si
C:\portatil-ia\windows\instalar.cmd E:\portatil\windows -Forzar
C:\portatil-ia\windows\instalar.cmd E:\portatil\windows -SoloVerificar
```

| Option | Purpose |
| --- | --- |
| `-Destino <path>` | Installation folder (first argument). It may be the installer's own folder, which then updates itself. |
| `-Si` | Do not ask for confirmation. |
| `-Forzar` | Download every assistant again even if it is up to date. |
| `-SoloVerificar` | Only verify the installation; no internet access and no changes. |

**Alternative: copy and update.** The Windows folder of the project contains no programs and no credentials, so it can also be copied to the drive as is (for example to `E:\portatil\windows`). Then run `E:\portatil\windows\actualizar.cmd` once: it downloads the four programs into that folder and verifies them. Until then, the launchers only report that the program is missing.

The official sources, checked against the hash each publisher releases:

| Assistant | Source | Package | Hash |
| --- | --- | --- | --- |
| Claude Code | `downloads.claude.ai/claude-code-releases`, `stable` channel | `win32-x64/claude.exe` | SHA-256 from the release manifest |
| Codex CLI | GitHub `openai/codex`, latest release | `codex-package-x86_64-pc-windows-msvc.tar.gz` | SHA-256 digest published by GitHub |
| OpenCode | GitHub `sst/opencode`, latest release | `opencode-windows-x64-baseline.zip` | SHA-256 digest published by GitHub |
| Antigravity CLI | Updater manifest used by Google's installer | `windows-x64` executable | SHA-512 from the manifest |

The x64 builds are always installed, and OpenCode's *baseline* build, so that the drive works on any PC: x64 programs also run on Windows on ARM, and the baseline build does not need AVX2. Downloads are staged in the Windows temporary folder and removed afterwards.

The installer refuses to run while an assistant from the destination is open, checks the free space on the drive and in the temporary folder, and asks before adding files to a folder that already contains something else.

## First start and credentials

The portable never uses the credentials of the PC it runs on. A new portable has none; each assistant stores its own the first time you sign in:

1. Start the launcher. It says that the portable has no credentials yet and opens the assistant without asking for a password.
2. Sign in with the assistant's own method: `/login` in Claude Code, `codex login` (or when Codex asks), `/connect` in OpenCode, Antigravity OAuth is blocked.
3. Close the assistant normally. The launcher asks for the portable password, encrypts the credentials, and removes the plain-text file.

**One password for the four assistants.** The first assistant that saves credentials asks for a new password twice and records a check value in `portatil.passcheck`. The others then ask for the same password and reject any other. From then on each start asks for the password once.

If the password prompt is cancelled or the assistant does not close normally, the plain-text credentials are kept and encrypted on the next start, so they are not lost.

## Daily use

Run a launcher from the drive:

```powershell
E:\portatil\windows\claude\claude.cmd
E:\portatil\windows\codex\codex.cmd
E:\portatil\windows\oc\opencode.cmd
E:\portatil\windows\antigravity\antigravity.cmd
```

Without arguments the launcher asks for the password (once credentials exist) and shows the workspace menu: choose a workspace, create one, or press Enter to cancel. Each workspace is a normal folder (`sesiones\<name>`, or `workspaces\<name>` for Codex) where you keep a project.

```powershell
E:\portatil\windows\claude\claude.cmd -Workspace my-project    open or create a workspace directly
E:\portatil\windows\claude\claude.cmd --version                other arguments go to the assistant
```

Always close the assistants normally before removing the drive: credentials are encrypted when the assistant exits.

For automation, the password can be passed in the `PORTATIL_PASSWORD` environment variable (or the older per-assistant names in the table below). The launcher reads it and removes it before starting the assistant. Do not store it in scripts or shell history.

## Updating

On the drive, run `actualizar.cmd` (double-click works). It downloads only the assistants that have a newer official version or missing files, and verifies the result. It accepts `-Si`, `-Forzar`, and `-SoloVerificar`.

Updating never touches `data`, `config`, `cache`, `sesiones`, `workspaces`, the `*.enc` credential files, or `portatil.passcheck`: sessions, credentials, and the password are kept. If a download fails or does not match its published hash, that assistant keeps its previous version and the error is reported.

`actualizar.cmd` does not change the scripts. To update the launchers or the installer, run `instalar.cmd` from the PC copy with the drive as the destination.

## Verification

After every installation or update, and with `-SoloVerificar`, the installer checks:

- every program file is identical to the verified download (inventory in `versiones.json`), and no unexpected files are in the program folders;
- the scripts are present, match the PC copy when installing from it, and have no syntax errors;
- the credential encryption works;
- the four programs start on this PC and report the installed version (run with their state redirected to a temporary folder, inside the installation folder);
- the credential state of each assistant: none yet, encrypted, or left unencrypted.

The result is **Todo correcto** (exit code 0), possibly with warnings, or a list of problems (exit code 2). Running the installer again, with `-Forzar` if needed, repairs them.

## Assistant details

| Detail | Claude Code | Codex CLI | OpenCode | Antigravity |
| --- | --- | --- | --- | --- |
| Program | `bin\claude.exe` | `bin\codex.exe` + `bin\codex-code-mode-host.exe`, `codex-path\`, `codex-resources\`, `codex-package.json` | `bin\opencode.exe` | `bin\agy.exe` |
| State redirected with | `CLAUDE_CONFIG_DIR` | `CODEX_HOME` | `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_CACHE_HOME` | `USERPROFILE`, `HOME`, `APPDATA`, `LOCALAPPDATA` |
| State folders | `data\claude` | `data\codex` | `data\opencode`, `config\opencode`, `cache\opencode` | `data\.gemini`, `config`, `cache` |
| Encrypted credentials | `data\claude\.credentials.json.enc` | `data\codex\auth.json.enc` | `data\opencode\auth.json.enc` | `data\.gemini\auth.json.enc` |
| Sign in | `/login` | `codex login` | `/connect` or `auth login` | Browser (Google) |
| Workspaces | `sesiones\` | `workspaces\` | `sesiones\` | `sesiones\` |
| Password variable | `PORTATIL_PASSWORD` or `CLAUDE_PASSWORD` | `PORTATIL_PASSWORD` or `CODEX_PORTABLE_PASSWORD` | `PORTATIL_PASSWORD` or `OPENCODE_PASSWORD` | `PORTATIL_PASSWORD` or `ANTIGRAVITY_PASSWORD` |

Paths are relative to the assistant's folder.

**Claude Code.** Configuration, projects, and history are in `data\claude` (`.claude.json`, `settings.json`, `projects\`, `sessions\`). The launcher disables the built-in updater. Claude Code may refresh its OAuth token while running; the new token is encrypted on exit.

**Codex CLI.** `data\codex` holds `config.toml`, sessions, skills, plugins, and logs. The launcher sets `cli_auth_credentials_store = "file"` in `config.toml` so Codex always keeps its login in `auth.json` (in the portable) and never in the Windows credential store. The program is the complete official standalone package; its parts must come from the same release, which the installer guarantees.

**OpenCode.** The session database, logs, and repository snapshots are in `data\opencode`; configuration and provider plugins in `config\opencode` (installed by OpenCode on first use); model caches in `cache\opencode`.

**Antigravity CLI.** OAuth sessions are blocked. Version and help commands use a portable profile and portable temporary directories. A separately configured portable Gemini API mode is not yet implemented.

Launcher options for testing and automation (not needed for normal use):

| Option | Purpose |
| --- | --- |
| `-Workspace <name>` | Open or create a workspace without the menu. |
| `-DataDir <path>` | Use another state folder inside this assistant folder. External and linked paths are rejected. |
| `-Password <text>` (also `-PortablePassword` in Codex) | Supply the password. Prefer `PORTATIL_PASSWORD`: a command-line value can be seen by other processes. |
| `-EncryptOnly` | Encrypt credentials left in plain text and exit. |

Only these exact option names belong to the launcher; abbreviations are not accepted, so every other argument (for example Claude's `-p`, `-c`, `-d`, or Codex's `-c`, `-p`) reaches the assistant unchanged. The Codex launcher passes its own `-c cli_auth_credentials_store='file'` overrides before the user's arguments.

## Troubleshooting

| Situation | What to do |
| --- | --- |
| Legacy Antigravity entries remain in the host credential store | Automatic host-store recovery is disabled. Existing entries need a separately reviewed manual recovery; the current launcher does not read them. |
| Forgot the password | It cannot be recovered. Delete every `*.enc` file and `portatil.passcheck`, then sign in again in each assistant; the first one asks for a new password. |
| Sign in with another account | Delete that assistant's `.enc` file (see [Assistant details](#assistant-details)), start it, and sign in. The password does not change. Signing out inside the assistant is not enough: the next start restores the saved credentials. |
| "Contrasena incorrecta" / exit code 2 when starting | Wrong password, or a damaged `.enc` file. After three attempts the launcher exits without changing anything. |
| Warning about credentials left unencrypted | An assistant did not close normally, or the password prompt was cancelled. Start that assistant and close it normally; the credentials are encrypted on start. |
| The installer reports FALLO | Run it again; use `-Forzar` if a file was altered. Downloads that fail keep the previous version. |
| "Hay asistentes del destino en ejecucion" | Close the assistants that run from the drive and try again. |
| No internet or a source is unreachable | The installer reports an error for that assistant and keeps what is installed. `-SoloVerificar` works offline. |
| Warning "instalado sin inventario" | The portable was installed by an older installer. Run `actualizar.cmd` once. |

## Security notes

- Supported assistant credential files are decrypted only for the session and encrypted on normal exit. Credential protection failures must be recovered before removing the drive. NTFS/POSIX permissions restrict access; exFAT and FAT have no file permissions.
- Always close the assistants normally before removing the drive, and never copy a plain-text credential file.
- The `.enc` files are only as strong as the password; use a long one.
- Back up the `*.enc` files and `portatil.passcheck` together if signing in again would be inconvenient.
- Revoke and regenerate any provider API key that was ever exposed in a terminal or a conversation.
- `versiones.json` detects corruption and accidental changes of the program files; it is stored on the drive, so it does not protect against someone who can modify the drive deliberately. Reinstall with `-Forzar` from a trusted PC if the drive may have been tampered with.
