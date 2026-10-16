# Architecture

Technical reference for maintaining the portable assistants. For installation and use, see the [project README](../README.md) and the guides in each version folder.

## Contents

- [Goals and constraints](#goals-and-constraints)
- [Repository layout](#repository-layout)
- [Launcher lifecycle](#launcher-lifecycle)
- [Credential stores](#credential-stores)
- [Credential encryption](#credential-encryption)
- [Common password](#common-password)
- [Windows version](#windows-version)
- [Linux and macOS versions](#linux-and-macos-versions)
- [Installers](#installers)
- [File formats](#file-formats)
- [Exit codes](#exit-codes)
- [Adding or changing an assistant](#adding-or-changing-an-assistant)
- [Testing changes](#testing-changes)
- [Known limitations](#known-limitations)

## Goals and constraints

- **Portable.** Runs from any folder, drive letter, or mount point, with no installation and no administrator rights. Paths are resolved at run time from the script's own location.
- **Portable authentication environment.** Assistants inherit only an allowlist of OS, locale, and terminal variables. Provider keys, tokens, authentication helpers, endpoint overrides, proxy settings, and agent sockets are excluded, including unknown variable names. Home directories, cloud CLI profiles (AWS, Boto, gcloud, Azure, Kubernetes), and global Git configuration are redirected into the portable. Each launcher also redirects assistant state and shuttles supported OS credential-store entries. These scripts are not an OS sandbox: programs and tools still have the current user's filesystem and OS access, and explicitly supplied project configuration or command arguments can request other locations.
- **Credentials encrypted at rest.** Credentials exist unencrypted only while an assistant runs. They are encrypted with a password-derived key (not DPAPI or a keyring), so a drive works on any PC.
- **Built-in runtimes only.** Windows: Windows PowerShell 5.1 (.NET Framework) and PowerShell 7, no modules (this rules out `AesGcm`, `??`, ternaries). Linux/macOS: POSIX `sh` (macOS ships bash 3.2 as `sh`) and Python 3.8+ standard library.
- **Programs from official sources.** Binaries are downloaded from the publishers and checked against their published hashes; the project holds only scripts.

## Repository layout

```
README.md               overview of the three versions
docs/ARCHITECTURE.md    this document
windows/                PowerShell version (see Windows version)
linux/                  Python version for Linux
macos/                  Python version for macOS
```

`linux/` and `macos/` contain **identical scripts** (`lib/*.py`, `lib/python.sh`, every `.sh`); they differ only in `portatil-programa.json` (download sources, `"system"`) and `README.md`. Keep them identical: edit in one folder and copy, then check with `diff -r linux macos`.

Each version folder is installed into its own folder of the drive, by default `<drive>/portatil/<windows|linux|macos>`.

## Launcher lifecycle

All launchers, in the three versions, follow the same sequence:

1. **Resolve paths** inside the installation, reject linked managed paths, and check that the program exists. Normal credential sessions acquire an exclusive per-assistant lock.
2. **Take the password from the environment.** `PORTATIL_PASSWORD` and the assistant's legacy variable (`CLAUDE_PASSWORD`, …) are read and removed, so the program never inherits them. On PowerShell 7 this needs `Remove-Item Env:`; `SetEnvironmentVariable($name, $null)` would still pass the name, empty, to child processes. An explicit `-Password` parameter takes precedence.
3. **Redirect state** (see each version) and disable the assistant's self-updater.
4. **Recover plaintext leftovers.** Supported credential files from an interrupted session are merged with the decrypted previous bundle, keeping newer plaintext. Encrypt-only mode handles coexistence of plaintext and encrypted files. Host credential stores are not inspected.
5. **Decrypt.** If a `.enc` exists: ask for the common password, decrypt, register the password if `portatil.passcheck` is missing, and restore the credentials (files with restricted permissions where the file system has them; store entries). A plain file that already exists next to the `.enc` is **kept**: it was left by a session that ended abruptly and is newer (for example a refreshed OAuth token, whose predecessor may already be invalid). A wrong password or corrupt file exits with code 2 and writes nothing. Without a `.enc`, the launcher says that the portable has no credentials yet; no password is asked.
6. **Workspace.** `-Workspace`/`--espacio <name>` opens or creates it; without arguments, a menu; with program arguments (for example `--version`), no workspace. Informational arguments (`--version`, `--help`, …) run without credentials.
7. **Run the program** in the workspace, in the foreground.
8. **Protect on exit** in cleanup: write and flush a private sibling temporary file, replace the encrypted copy, then remove supported plaintext files. Keep recoverable plaintext if protection fails. Release the session lock even on errors. The launcher never moves or restores host credential-store entries.

## Credential stores

Several assistants keep their login in the operating system's credential store instead of a file. Left alone, the login would stay on the PC, would not travel with the drive, and would not be protected by the portable password.

| Assistant | Windows | Linux | macOS |
| --- | --- | --- | --- |
| Claude Code | `.credentials.json` in `CLAUDE_CONFIG_DIR` | same | Keychain, keyed to `CLAUDE_CONFIG_DIR`; no option to use a file |
| Codex CLI | `cli_auth_credentials_store`: `file`, `keyring`, or `auto` | same | same |
| OpenCode | `auth.json` (and `mcp-auth.json`) in `XDG_DATA_HOME/opencode` | same | same |
| Antigravity CLI | Credential Manager, target `gemini:antigravity` | Secret Service (D-Bus); files in its home when there is no D-Bus session | Keychain (service `gemini`, account `antigravity`) |

How each case is handled:

- **Codex:** both login and MCP credential stores are forced to `file` using explicit CLI overrides. Configuration rewriting also sets the file store. Login is `CODEX_HOME/auth.json`; MCP OAuth is `CODEX_HOME/.credentials.json`. Both are protected on exit.
- **Antigravity on all systems:** normal OAuth sessions are blocked before any host-store inspection. The old native store shuttle is disabled. Only informational commands are available; a portable Gemini API mode is not yet implemented. See [ISOLATION.md](ISOLATION.md).
- **Legacy Antigravity files:** credential-looking files can still be detected during verification, but startup does not migrate them or inspect a native keyring.
- **Claude Code on macOS: token.** Instead of `/login`, the launcher stores a one-year token pasted interactively after `claude setup-token` and passes the decrypted portable token as `CLAUDE_CODE_OAUTH_TOKEN`. Anthropic documents that this token only allows model requests (no claude.ai connectors, no Remote Control). Host environment tokens are never imported or passed to the child. Version checks and installer verification use the same restricted environment policy.

## Credential encryption

Identical in the three versions (`Protect-PortableData` in `windows/portable-crypto.ps1`, `protect` in `lib/portatil.py`), so blobs are interchangeable. AES-GCM is not available in .NET Framework, so the format is encrypt-then-MAC:

- **Key derivation:** PBKDF2-HMAC-SHA256, 210,000 iterations, 16-byte random salt, 64 bytes of output. Bytes 0–31 are the AES-256 key; bytes 32–63 are the HMAC-SHA256 key. The password is UTF-8.
- **Encryption:** AES-256-CBC with PKCS#7 padding and a 16-byte random IV.
- **Authentication:** HMAC-SHA256 over `magic ‖ salt ‖ IV ‖ ciphertext`, verified in constant time **before** decrypting.

| Offset | Length | Field |
| --- | --- | --- |
| 0 | 8 | Magic, ASCII: `PORTCC02` Claude, `PORTCX02` Codex, `PORTOC02` OpenCode, `PORTAG02` Antigravity, `PORTPW02` password check (`PORTVF02` only in the installers' self-test) |
| 8 | 16 | PBKDF2 salt |
| 24 | 16 | AES-CBC IV |
| 40 | n (multiple of 16) | Ciphertext |
| 40 + n | 32 | HMAC-SHA256 tag |

The minimum valid size is 88 bytes. A wrong password and a modified file give the same error. The per-assistant magic prevents decrypting one assistant's file as another's.

The Python version implements AES-256 itself (FIPS-197; the standard library has none, and calling `openssl enc -K` would put the key on a command line visible to other users). PBKDF2 and HMAC come from `hashlib`/`hmac`. It is checked against the FIPS-197 C.3 and SP 800-38A F.2.5 vectors and against the PowerShell implementation in both directions.

## Common password

The four assistants of a portable share one password without storing it. `portatil.passcheck` at the root of the portable is the constant `portatil-password-check` encrypted with magic `PORTPW02`. `Get-PortablePassword` / `get_password(root, tool, provided, for_new_credentials)`:

| Situation | Behaviour |
| --- | --- |
| `portatil.passcheck` exists | A password from `-Password`/the environment is checked against it (error if wrong). Otherwise up to 3 prompts, each checked. |
| No passcheck, decrypting an existing `.enc` | One prompt; decryption validates it, then the launcher registers it. |
| No passcheck, first save | Prompt twice, require both entries to match, and write `portatil.passcheck`. A password from the environment is registered directly. |

## Windows version

| File | Role |
| --- | --- |
| `<assistant>\<name>.cmd` | Entry point: uses `pwsh.exe` if present, else `powershell.exe`, with `-ExecutionPolicy Bypass`. |
| `<assistant>\<name>.ps1` | Launcher (lifecycle above). |
| `portable-crypto.ps1` | Encryption, common password, environment cleanup, file ACLs (best effort: exFAT/FAT have none). |
| `portable-keyring.ps1` | Legacy recovery helper retained in the source; not called by launchers/verifier or copied by the current installer. |
| `portatil-programa.psd1` | Scripts and download sources. |
| `instalar.ps1`/`.cmd`, `actualizar.cmd` | Installer; `actualizar.cmd` runs it on its own folder. |

State redirection:

Before assistant-specific variables are applied, `Get-PortableChildEnvironment` / `child_environment` constructs a fresh environment. `HOME`, `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, and the four `XDG_*_HOME` paths are portable defaults. AWS, Boto, gcloud, Azure, Kubernetes, and global Git profile paths are also portable defaults. API key and token variables are not inherited, even for unknown providers. Proxy settings and authentication helpers from the host are excluded. On Windows, `Set-PortableChildEnvironment` applies this environment only to the launcher's process; the parent shell's environment is unaffected. The portable password is consumed before this step. Installer staging and version-check profiles live under `<installation>/.portable-tmp`. Python download subprocesses also use sanitized environments and disable curl startup configuration.

| Assistant | Variables | Also |
| --- | --- | --- |
| Claude Code | `CLAUDE_CONFIG_DIR = claude\data\claude` | `DISABLE_AUTOUPDATER=1`, `CLAUDE_NO_UPDATE_NOTIFIER=1` |
| Codex CLI | `CODEX_HOME = codex\data\codex` | `codex-path` first in `PATH`; file store pinned |
| OpenCode | `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_CACHE_HOME` under `oc\` | `OPENCODE_DISABLE_AUTOUPDATE=1` |
| Antigravity | portable profile for informational commands | OAuth sessions blocked; native store access disabled |

Encrypted Windows files: Claude uses `claude/data/claude/.credentials.json.enc`; Codex uses `codex/data/codex/auth.json.enc` and `.credentials.json.enc`; OpenCode uses `oc/data/opencode/auth.json.enc`, now a versioned bundle for both `auth.json` and `mcp-auth.json` with legacy raw-auth compatibility. Existing Antigravity encrypted files are preserved but not used for OAuth startup.

## Linux and macOS versions

| File | Role |
| --- | --- |
| `<assistant>/<name>.sh` | Entry point (POSIX `sh`): sources `lib/python.sh` and runs `lib/lanzador.py <assistant>`. |
| `lib/python.sh` | Finds Python 3.8+ (`python3`, `python3.x`, `python`) or explains how to install it. |
| `lib/portatil.py` | Encryption (with a pure-Python AES), common password, private file writes, host system/architecture. |
| `lib/lanzador.py` | One launcher for the four assistants (table `TOOLS`), lifecycle above. |
| `lib/instalar.py` | Installer; `instalar.sh` runs it, `actualizar.sh` runs it on its own folder. |
| `portatil-programa.json` | `system`, scripts, and download sources. |

Differences from Windows:

- **Programs per architecture:** `<assistant>/prog/<arch>/` (`x64`, `arm64`). The launcher picks the host's; on Apple silicon it falls back to `x64` (Rosetta 2).
- **One encrypted bundle per assistant:** `<assistant>/credenciales.enc` = `{"formato": "portatil-2", "archivos": {relative path: base64}, "token": …, "llavero": base64}`. Paths are checked to stay inside the assistant folder when restored.
- **State redirection:** Claude `CLAUDE_CONFIG_DIR`; Codex `CODEX_HOME`; OpenCode `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, `XDG_STATE_HOME`; Antigravity `HOME` plus the four `XDG_*` variables. Self-updaters disabled as on Windows.
- **Drives that cannot execute programs:** startup fails closed without making a copy on the host. Use an executable mount. Existing program permissions may be corrected inside the portable.
- **Native credential stores:** normal launcher and verification paths never query them. macOS native `security` calls are disabled; only the explicit fake test hook can emulate a store.
- **Signals:** while the assistant runs, the launcher ignores SIGINT, SIGQUIT, SIGTERM, and SIGHUP (the child gets the defaults back), so Ctrl+C or closing the terminal reaches the assistant and the launcher still encrypts afterwards. Without a terminal the first-save prompt fails and the credentials stay for the next start.
- **System check:** the launcher refuses to run when `portatil-programa.json` names another system.

## Installers

Windows: `instalar.ps1 [-Destino <dir>] [-Si] [-Forzar] [-SoloVerificar]`. Linux/macOS: `instalar.py [DEST] [--si] [--forzar] [--solo-verificar] [--arq actual|x64|arm64|todas]`. Both work the same way:

1. **Destination.** Without one, list removable drives (Windows: `Get-Volume`; Linux: mounts under `/media`, `/run/media`, `/mnt`; macOS: `/Volumes`; volumes under 1 GB are skipped) and suggest `<drive>/portatil/<system>`. A bare drive root gets that suffix. The destination may be the installer's own folder (self-update); the scripts are then not copied. A non-empty folder that is not a portable needs confirmation.
2. **Plan** (skipped by solo-verificar): refuse if a process runs from inside the destination; query the latest release of each assistant (and architecture); compare with `versiones.json` → `instalar`, `actualizar`, `al dia`, `reparar` (an inventoried file is missing), `reinstalar` (forzar), `error`; check free space on the destination and in the temporary folder (archives ×3; 250 MB when no size is published); show the plan and ask. Linux/macOS: by default the host architecture; architectures already installed are always kept up to date; musl systems get the `-musl` builds; on another system an explicit `--arq` is needed unless the destination already has architectures.
3. **Install:** copy the scripts (Windows also removes `ObsoleteFiles`, scripts of earlier versions such as `actualizar.ps1`); for each assistant: download to a staging folder (curl with retries, or the runtime's HTTP client), check the hash, unpack (tar/zip, rejecting paths outside the folder and links), check that the expected files exist, compute the SHA-256 inventory, place it (Windows: `robocopy /MIR /FFT` per program folder; Linux/macOS: copy to `prog/<arch>.nuevo`, then swap with the old folder), unblock/unquarantine, save `versiones.json`. A failure affects only that assistant, which keeps its previous version.
4. **Verify:** inventory hashes and unexpected files; scripts present, equal to the source when copied from it, and parse/compile (PowerShell parser; `compile()` and `sh -n`); a crypto round trip with the destination's own module; `--version` of each program the host can run, with its state redirected to a throwaway folder and a 60-second timeout (other systems/architectures are reported as INFO); credential state (encrypted, none, or left unencrypted; Windows also reports pending Credential Manager entries).

### Release sources

| Type | Query | Hash |
| --- | --- | --- |
| `claude` | `GET <baseUrl>/<channel>` → version; `GET <baseUrl>/<version>/manifest.json` → `platforms.<platform>.{binary, checksum, size}`; binary at `<baseUrl>/<version>/<platform>/<binary>` | SHA-256 |
| `github` | `GET https://api.github.com/repos/<repo>/releases/latest`, asset by name; version = `tag_name` without the prefix | SHA-256 from the asset's `digest`; releases without one are rejected |
| `agy` | `GET <manifest>` → `{version, url, sha512}` | SHA-512 |

These are the endpoints used by the official installers (`claude.ai/install.ps1`, `antigravity.google/cli/install.ps1`).

## File formats

`portatil-programa.psd1` (Windows):

```powershell
@{
  RootFiles = @('portable-crypto.ps1', 'portable-keyring.ps1', ...)
  Tools = @{ <folder> = @{
    Files = @('<name>.cmd', '<name>.ps1'); Dirs = @('bin', ...); PackageFiles = @(...)
    Exe = 'bin\<program>.exe'
    Source = @{ Type = 'claude'|'github'|'agy'; Extract = 'none'|'zip'|'targz'; Into = '.'; ... } } }
}
```

`portatil-programa.json` (Linux/macOS):

```json
{ "system": "linux",
  "rootFiles": ["instalar.sh", "lib/portatil.py", "..."],
  "tools": { "<folder>": { "launchers": ["<name>.sh"], "exe": "<path in prog/<arch>>",
    "source": { "type": "claude|github|agy", "extract": "none|zip|targz",
                "platform|asset|manifest": { "x64": "...", "arm64": "..." },
                "platformMusl|assetMusl": { "...": "..." } } } } }
```

`versiones.json` — written after each successful installation; keys are the assistant (Windows) or `<assistant>/<arch>` (Linux/macOS):

```json
{ "claude/x64": { "version": "2.1.274", "source": "https://…/linux-x64/claude",
                  "installed": "2026-09-25 01:40", "files": { "claude/prog/x64/claude": "<sha256>" } } }
```

## Exit codes

| Program | Code | Meaning |
| --- | --- | --- |
| Launchers | assistant's code | Normal run |
| | 1 | Program missing, invalid workspace, wrong system, no token (macOS), or leftovers that could not be encrypted |
| | 2 | Credentials could not be decrypted (wrong password or corrupt file) |
| | 3 | Windows Codex only: credentials could not be secured |
| Installers | 0 | Everything correct (possibly with warnings), or cancelled |
| | 1 | Not started: nothing to verify, destination in use, not enough space, architecture needed |
| | 2 | A download or the verification failed |

## Adding or changing an assistant

1. Find the environment variables that move **all** of the program's state into its folder, its self-updater switch, and **where it stores credentials** on each system (files, keyring, Keychain, Credential Manager). Verify the isolation by running it from a copy and checking that nothing changes in the user's profile or credential store.
2. Windows: create `<folder>\<name>.ps1` from an existing launcher (keep the lifecycle; new 8-character magic `PORT??02`) and a `.cmd`; add it to `Tools` in the `.psd1`; add its `--version` environment (`$envByTool`) and credential paths (`$credPaths`) in `instalar.ps1`.
3. Linux/macOS: add an entry to `TOOLS` in `lib/lanzador.py`, a `.sh` launcher, and the sources in both `portatil-programa.json`; copy the scripts to the other folder.
4. Sources must publish a hash; add a type to `Get-LatestRelease`/`latest_release` if needed. Never install without a hash check.
5. Document it in the version READMEs.

To change a source or channel (for example Claude's `stable` → `latest`), edit only the manifests.

## Testing changes

Run the host credential environment regression suite from the project root with `python -B -m unittest discover -s tests -v`. It uses temporary portable copies, dummy host secrets, and simulated programs. Windows launcher subprocess checks require PowerShell 7; Linux/macOS logic is also exercised through the documented test hooks. The tests never use real assistant credentials or modify host credential stores.

The launchers are tested without the real programs:

- **Windows:** tests run disposable launcher copies with a copied command interpreter as a simulated assistant. Dummy provider and MCP files are restored during the session and protected afterward. Tests do not write host Credential Manager entries.
- **Linux/macOS (any OS, including Windows):** disposable test harnesses explicitly set the imported launcher's `SYSTEM` and the helper's in-memory `_TEST_PROGRAM` or `_TEST_SECURITY` attributes. Production launchers do not accept environment variables that replace executables or credential-store helpers. The installers can run against another system with `--arq` to test downloads, hashes, unpacking, and the inventory.

With `PORTATIL_PASSWORD` set, dummy credential tests need no prompt. Cover first save, subsequent restore, wrong passwords, newer plaintext, encrypt-only recovery, cleanup errors, exclusive locks, external/junction paths, portable CWD and temporary files, and absence of inherited host secrets. Native Keychain/Credential Manager recovery is not part of the current launchers. Installers should be tested separately for hash verification, promotion failures, and portable staging.

## Known limitations

- **Linux and macOS not yet run with the real programs.** Their logic and the downloads have been tested, but not Claude Code, Codex, OpenCode, and Antigravity running on those systems (in particular Antigravity's file fallback on Linux, its Keychain item name on macOS, and the setup-token flow).
- **Antigravity OAuth is blocked.** Its native credential stores conflict with folder-only credential management. Legacy credential files are preserved for separate recovery.
- **Claude Code on macOS uses a token**: no claude.ai connectors or Remote Control, and running `/login` inside the portable would write to the Mac's Keychain.
- **Signing out does not stick.** If an assistant deletes its credentials, the launcher has nothing to encrypt and the previous `.enc` stays; to switch accounts, delete the `.enc`.
- **Latest release only**; no pinning or rollback.
- **Integrity, not authenticity, of installed files.** `versiones.json` lives on the drive; it detects corruption and accidental changes, not deliberate tampering by someone with write access.
- **Undocumented endpoints.** The Claude Code and Antigravity sources are the endpoints of their official installers.
- **Third-party host access:** temporary defaults and installer staging are portable, but an assistant can ignore them or explicitly access host files/services. These scripts are not an OS sandbox; see [ISOLATION.md](ISOLATION.md).
