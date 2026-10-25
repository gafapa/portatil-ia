# Portable coding assistants

Portable launchers for Claude Code, Codex CLI, OpenCode, and Google Antigravity CLI on Windows, Linux, and macOS. Assistant profiles, supported credential files, caches, sessions, and temporary files are managed inside the installation folder. Antigravity OAuth sessions are currently blocked because they use the host credential store; informational commands remain available.

The project contains **only scripts**: the assistants are downloaded from their official sources by the installer, checked against the hash each publisher releases, and kept up to date with one command.

| Folder | For | Scripts | Guide |
| --- | --- | --- | --- |
| [`windows/`](windows/) | Windows 10/11 | PowerShell (5.1 or 7), `.cmd` launchers | [windows/README.md](windows/README.md) |
| [`linux/`](linux/) | Linux x64/ARM64 | Python 3.8+, `sh` launchers | [linux/README.md](linux/README.md) |
| [`macos/`](macos/) | macOS (Apple silicon, Intel) | Python 3.8+, `sh` launchers | [macos/README.md](macos/README.md) |
| [`docs/`](docs/) | maintainers | technical reference | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |

## What every version does

- **Downloads from the official sources** (Anthropic's release server, the GitHub releases of OpenAI Codex and OpenCode, Google's Antigravity updater) and refuses any download whose hash does not match.
- **Keeps everything in the portable folder**: each launcher redirects the assistant's configuration, history, and sessions into it.
- **Does not inherit the PC's API keys or tokens.** Child processes receive only essential OS, locale, and terminal variables. Home, cloud CLI profiles, and global Git configuration point inside the portable. Each assistant uses its portable login; macOS Claude tokens must be configured interactively, never imported from the host environment.
- **Keeps credentials encrypted** (AES-256 + HMAC-SHA256, key from PBKDF2 with 210,000 iterations) with **one password common to the four assistants**. They exist unencrypted only while an assistant is running.
- **Verifies itself**: every installation, update, or `--solo-verificar`/`-SoloVerificar` run checks the program files against the verified downloads, that the programs start, and the state of the credentials.

The three versions use the same encrypted format and the same password check, but each keeps its own programs and credentials.

The launchers block automatic inheritance of host authentication and redirect standard credential profiles. They run with the current user's permissions; they are not an OS sandbox against deliberate reads of host files or credential stores by an assistant or its tools. Host proxy settings and authentication helpers are excluded from assistant and download environments.

## Putting the three versions on one USB drive

Install each version into its own folder of the drive, from a PC of that system:

```
E:\portatil\windows\     Windows:  C:\portatil-ia\windows\instalar.cmd
/Volumes/USB/portatil/macos/        macOS:    sh macos/instalar.sh
/media/$USER/USB/portatil/linux/    Linux:    sh linux/instalar.sh
```

Each installer suggests `<drive>/portatil/<system>` by default. The Linux and macOS installers can also prepare their folder from another system with `--arq x64`, `arm64`, or `todas` (the programs are then verified by hash only, as they cannot be started there).

Alternatively, copy the project folder to the drive as is (it contains no programs and no credentials) and run the updater of each version once: `windows\actualizar.cmd`, `sh linux/actualizar.sh`, `sh macos/actualizar.sh`.

## Where the assistants keep their login

Some assistants store their login in the operating system's credential store instead of a file, which would leave it on the PC. Each version handles that:

| | Windows | Linux | macOS |
| --- | --- | --- | --- |
| Claude Code | file, encrypted | file, encrypted | one-year token (`claude setup-token`), encrypted; the Keychain is not used |
| Codex CLI | file (file store forced), encrypted | same | same |
| OpenCode | file, encrypted | file, encrypted | file, encrypted |
| Antigravity CLI | OAuth blocked | OAuth blocked | OAuth blocked |

The launchers and verifier no longer read, rename, back up, or restore host credential-store entries. Existing Antigravity encrypted files are preserved, but OAuth startup fails closed. A future portable API mode requires a separately configured portable key; host keys are never imported. See [the isolation policy](docs/ISOLATION.md) for the exact guarantees and limitations.

## Moving Codex between computers

Sign in through the portable launcher (`windows\codex\codex.cmd login`, `sh linux/codex/codex.sh login`, or `sh macos/codex/codex.sh login`). Close Codex and wait for the launcher to finish protecting credentials before safely ejecting the drive. On another computer of the same OS, run that launcher and enter the same portable password. Move the complete installation, including `portatil.passcheck`, encrypted credentials, configuration, sessions, and workspaces.

Codex's account and MCP logins use files inside the portable, encrypted between sessions. Its SQLite state and logs are pinned to the current portable path at each launch, including after a drive-letter change. Storage overrides in Codex arguments are rejected; normal model options and nested MCP command arguments remain available. Existing `config.toml` content is preserved. Successful Codex logout also updates the encrypted state, so the next machine does not restore an old login.

Use a drive whose filesystem is writable and executable on the target computers. NTFS/ext4 permissions can still restrict access for a different OS user; exFAT avoids per-user ownership restrictions but provides no file ACL protection. Browser authorization cookies belong to the browser, and service-side token expiration or revocation can still require signing in again. Separate OS folders do not automatically synchronize their logins.

## Testing status

Earlier Windows versions were tested on Windows 11 with real programs (Windows PowerShell 5.1 and PowerShell 7). The current folder-only hardening has been tested with simulated assistants on Windows and requires renewed native integration validation. The Linux and macOS versions have been tested with the real downloads (hashes, unpacking, inventory) and with simulated programs and a simulated Keychain for the launchers; they have not yet been run with the real programs on Linux and macOS computers. See `docs/ARCHITECTURE.md` for how they were tested.
