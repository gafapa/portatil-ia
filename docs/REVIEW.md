# Project review

Review date: 2026-09-30.

## Original review: scope and outcome

Reviewed the Windows, Linux, and macOS installers, launchers, encryption helpers, download manifests, and documentation. This checkout contains scripts only: no installed assistant binaries, dependency lockfiles, automated test suite, or Git metadata. Consequently, installed assistant versions and binary vulnerabilities cannot be assessed here.

The encryption primitives passed the checks below, but credential handling has significant gaps. Fix host credential inheritance, unprotected Windows OpenCode MCP tokens, unsafe encrypted writes, and concurrent session handling before relying on the README's isolation and encryption guarantees.

The initial review added only this report. Reproductions used dummy credentials, temporary directories, mocked failures, and a copied Windows command interpreter as a simulated assistant. The subsequent R1 correction is recorded below; the final folder-only hardening status appears at the end of this report.

## Follow-up: host API credential isolation

R1 was addressed after the review. All launchers now build assistant environments from an explicit allowlist of essential OS, locale, and terminal settings. Unknown environment variables are excluded along with known API keys, tokens, authentication helpers, endpoint overrides, proxy settings, and agent sockets. Home, standard cloud CLI credential profiles, and global Git configuration point inside the portable. Installer version checks use the same policy. macOS Claude no longer imports `CLAUDE_CODE_OAUTH_TOKEN` from the host; only its stored portable token is passed to the child.

Validation: `python -B -m unittest discover -s tests -v` passed five regression tests, including real simulated child processes for all four Windows launchers and all eight Linux/macOS informational launcher combinations. Tests also confirmed unknown-provider variable blocking, portable profile paths, Linux/macOS source parity, and preservation of the stored portable Claude token. All seven PowerShell scripts parsed successfully. Native Linux/macOS assistant execution and PowerShell 5.1 runtime remain unverified.

This prevents automatic environment inheritance and default profile discovery; it does not provide OS-level isolation. Assistants and their tools still run with the user's permissions. Blocking deliberate reads of arbitrary host files, credential stores, or metadata services requires a sandbox or a separate execution identity. R2 through R9 remain open.

## Prioritized findings

### R1 — High: assistants inherit the host's API credentials

Locations: `linux/lib/lanzador.py:235`, its identical macOS copy, and the Windows launchers' environment setup.

`environment()` copies `os.environ` and changes state directories; it does not remove provider authentication variables. Windows launchers likewise retain the parent environment. Password variables are cleared, but provider keys are not. Claude's OAuth token is removed only in the macOS token mode.

Evidence: with a dummy `ANTHROPIC_API_KEY` set in the test environment, the Claude child environment still contained it. This contradicts the README's claim that host credentials are never used. Anthropic documents that this variable can select API authentication and billing; OpenCode also supports environment-based provider authentication. See [Claude API key handling](https://support.claude.com/en/articles/12304248-manage-api-key-environment-variables-in-claude-code) and [OpenCode providers](https://opencode.ai/docs/providers/).

Correction: build a deliberate child environment policy covering supported providers, cloud authentication, authentication helpers, and endpoint overrides. Clear host authentication by default; explicitly load portable credentials when requested. Document the boundary: redirecting state directories does not isolate subprocesses from every host credential or configuration file.

### R2 — High: Windows OpenCode MCP credentials remain unencrypted

Locations: `windows/oc/opencode.ps1:66`, `windows/oc/opencode.ps1:98`, `windows/instalar.ps1:624`.

The Windows launcher encrypts only `auth.json`. It never includes `mcp-auth.json`, unlike the Linux/macOS launchers. The Windows verifier also omits this file and can report the credential state as protected while MCP tokens remain in plaintext.

Evidence: ran a copied launcher with dummy `auth.json` and `mcp-auth.json` and a simulated assistant. It exited with code 0, produced `auth.json.enc`, deleted plaintext `auth.json`, and left plaintext `mcp-auth.json` untouched. The [OpenCode MCP documentation](https://opencode.ai/docs/mcp-servers/) confirms this token file's role.

Correction: encrypt both files in a versioned bundle, preserve compatibility with existing single-file encrypted credentials, and include both files in verification and interrupted-session recovery.

### R3 — High: encrypted credential saves overwrite the only previous copy

Locations: `linux/lib/portatil.py:288`, its macOS copy, `windows/claude/claude.ps1:151`, `windows/codex/codex.ps1:108`, `windows/oc/opencode.ps1:106`, `windows/antigravity/antigravity.ps1:176`, and password-check registration.

Python opens the destination with `O_TRUNC`; Windows uses `WriteAllBytes` directly. A partial write destroys the previous valid encrypted copy before the replacement is complete. Keeping current plaintext on failure does not recover older bundle entries that existed only in the overwritten archive, and startup can subsequently reject the corrupt archive.

Evidence: injected a write failure after ten bytes. A valid 104-byte encrypted file was replaced by a ten-byte corrupt file.

Correction: write a uniquely named private temporary file in the destination directory, flush and synchronize it, verify the new blob, then replace the destination atomically where supported. Preserve a recoverable backup for removable-media failure scenarios. Apply the same discipline to `portatil.passcheck` and inventories. Atomic replacement alone does not guarantee durability after sudden USB removal.

### R4 — High: concurrent sessions can interfere with each other's credentials

Locations: launcher startup and cleanup across all platforms; `windows/portable-keyring.ps1:157`; `linux/lib/lanzador.py:508` and its macOS copy.

There is no launcher-owned exclusive session lock. Two instances of the same assistant share plaintext credentials and encrypted files. One instance can encrypt and delete credentials while the other is still running. For Antigravity, a second macOS instance can interpret the first instance's active Keychain backup as an interrupted session; Windows instances also share global backup and pending target names. Different USB installations therefore need host-level coordination for the same credential-store entries.

Evidence level: static control-flow review; no real concurrent Keychain or Credential Manager experiment was performed.

Correction: take an exclusive lock before recovery or decryption, hold it through cleanup, and make updates respect it. Use a host-wide lock for shuttled credential-store entries, including sessions from different portable roots. Define safe stale-lock recovery.

### R5 — High: macOS Keychain errors are treated as missing credentials

Locations: `macos/lib/lanzador.py:130`, `macos/lib/lanzador.py:146`, `macos/lib/lanzador.py:342`, and identical shared Linux code.

`keychain_get()` returns `None` for every nonzero exit status, including locked-store and access errors. `keychain_delete()` ignores its exit status entirely. The launcher can consequently proceed as though there were no host credentials or declare cleanup complete without proving that the live portable secret was removed. In `protect()`, live and pending reads also occur before its cleanup `try/finally`; changing reads to raise must include moving them inside that protected scope.

Evidence: a mocked failed Keychain read returned `None`, indistinguishable from a missing item. Actual macOS behavior was not exercised.

Correction: distinguish the documented item-not-found result from access and transport failures, stop on unexpected errors before running the assistant, check deletions, and retain a recovery record until cleanup is verified.

### R6 — Medium: valid indented TOML tables break Codex's file-store pinning

Locations: `linux/lib/lanzador.py:253`, its macOS copy, `windows/codex/codex.ps1:67`.

The head/table split recognizes `\n[` or an opening `[` at the start of the file, but does not recognize valid indented table headers. Its regular expression can therefore replace a nested key instead of setting the required top-level key. It can also alter matching text inside multiline strings because it does not parse TOML.

Evidence: starting with `  [model_provider]\ncli_auth_credentials_store = "keyring"\n` produced a parsed document containing only `model_provider.cli_auth_credentials_store = "file"`; the required root key was absent. This input demonstrates accidental modification of a nested key. The Windows implementation has the same table-boundary assumption.

Correction: use a TOML-aware implementation or a constrained scanner that understands table headers and strings, preserves unrelated settings, and verifies the resulting root value. Include ordinary tables, indented tables, CRLF, comments, and multiline strings in regression cases.

### R7 — Medium: encrypt-only mode skips plaintext alongside an encrypted copy

Locations: `linux/lib/lanzador.py:299`, `linux/lib/lanzador.py:515`, their macOS copies, `windows/claude/claude.ps1:162`, `windows/oc/opencode.ps1:191`, and the Antigravity plaintext recovery condition at `windows/antigravity/antigravity.ps1:273`.

The leftover predicate generally recognizes plaintext only when no encrypted copy exists. With both present after an interrupted session, encrypt-only mode can exit successfully and claim there is nothing to encrypt. Windows Codex has separate handling and should not be assumed to have this exact defect.

Evidence: for a dummy Codex Python launcher with both `auth.json` and `credenciales.enc`, `secret_files()` found the plaintext file while `has_leftovers()` returned false. The encrypt-only branch then bypasses recovery.

Correction: make encrypt-only mode consider all current plaintext, decrypt and merge the previous bundle when needed, preserve newer plaintext, and report success only after the selected secrets have actually been secured.

### R8 — Medium: failed updates do not reliably preserve the previous installation

Locations: `windows/instalar.ps1:475`, `windows/instalar.ps1:484`, `linux/lib/instalar.py:428`, `linux/lib/instalar.py:433`, and the macOS copy.

Windows mirrors package directories directly into the live installation. A copy failure can leave a mixed or incomplete version despite the error message promising that the previous version is retained.

Python stages the new tree, but if moving the old tree aside succeeds and promoting the new tree fails, it does not roll back. A later attempt unconditionally deletes `.anterior`, potentially deleting the recoverable original. The disk-space estimate at `linux/lib/instalar.py:718` counts net growth even though staging next to the old installation needs space for the complete new tree.

Evidence level: static inspection of update failure paths; no installed binaries were changed.

Correction: use recoverable staging and promotion on every platform, restore the old tree on promotion failure, retain recoverable leftovers until their roles are resolved, and commit inventory only after promotion. Calculate peak disk usage rather than only net growth.

### R9 — Medium: cleanup failures can return a successful assistant exit code

Locations: `linux/lib/lanzador.py:342`, `linux/lib/lanzador.py:585`, their macOS copies, `windows/claude/claude.ps1:143`, `windows/oc/opencode.ps1:98`, and `windows/antigravity/antigravity.ps1:160`.

These cleanup routines catch credential protection failures and warn, while normal session paths still return the assistant's code. An assistant that exits successfully can therefore leave unencrypted credentials while the launcher returns 0. Windows Codex already has a separate protection failure exit code in its documented behavior.

Evidence level: static control-flow review.

Correction: return an explicit cleanup result and a consistent nonzero launcher code when credentials cannot be protected or deleted. Keep recoverable plaintext, explain its location, and distinguish assistant failure from protection failure in documentation.

## Updates and maintenance

Live metadata checks during this review returned:

| Component | Observed result | Limit |
| --- | --- | --- |
| Claude stable channel | `2.1.280` | Version endpoint only; no binary downloaded. |
| Antigravity | `1.2.14` | Windows x64, Linux x64, and macOS ARM64 manifest checks returned URL and SHA-512 fields; binary contents were not checked. |
| OpenCode | Release page redirected to `anomalyco/opencode`, `v1.18.33` | GitHub API requests from the local environment returned HTTP 403 rate-limit errors; asset availability and digest fields were not verified. |
| Codex | Local release API request rate-limited | Exact current package availability and checksums remain unverified. |

Sources: [Claude stable channel](https://downloads.claude.ai/claude-code-releases/stable), [Antigravity Windows manifest](https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/windows_amd64.json), [Antigravity Linux manifest](https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json), [Antigravity macOS manifest](https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/darwin_arm64.json), and [OpenCode release](https://github.com/anomalyco/opencode/releases/tag/v1.18.33).

Recommended maintenance:

- Update the OpenCode repository references from the redirecting `sst/opencode` location to its current canonical repository after verifying all configured asset names and digests. A redirect is not itself an installation defect.
- Add an optional GitHub token for release metadata, with a dedicated scope and without forwarding that token to assistants. Keep checksum verification mandatory and distinguish rate limiting from missing release assets.
- Prefer a maintained Python runtime, such as 3.11 or later, over the advertised 3.8 baseline. Python 3.8 and 3.9 are end-of-life according to the [Python version status](https://devguide.python.org/versions/). Compatibility with an old interpreter does not mean it receives security fixes.
- Add version pinning and rollback. Automatic latest-release installation makes upstream credential-location changes immediately relevant to portable security.
- Check program integrity before running or restoring secrets. The existing verification command checks a mutable local inventory; it is a corruption check, not protection against an attacker who can change scripts and inventory together.
- Preserve shared Linux/macOS script parity through an automated check or a shared source-generation step.
- Add a small executable regression suite for credential lifecycle behavior, interrupted saves, concurrent sessions, configuration rewriting, and failed update promotion. The architecture document describes tests, but the checkout does not contain them.
- Run native integration tests on Linux and macOS with the actual assistants before advertising complete host isolation. Antigravity credential discovery currently depends on inferred names, filename matching, depth, and size limits.
- Define sign-out behavior explicitly. Existing encrypted credentials survive when an assistant removes its plaintext credentials; the architecture document already acknowledges that sign-out does not persist.
- Harden filesystem boundaries: `restore_bundle()` uses lexical path normalization rather than rejecting symlinked parent directories, and `write_private()` follows links. Python versions before 3.12 also lack the selected TAR data filter; explicitly reject archive entries other than ordinary files and directories.

## Validation performed

| Check | Result |
| --- | --- |
| Python syntax, six source files | Passed using Python 3.12.10; compilation performed in memory. |
| PowerShell syntax, seven scripts | Passed with the PowerShell 7 parser. |
| Linux/macOS `.py` and `.sh` parity | Identical. |
| AES-256 single-block FIPS test vector | Passed. |
| Python encryption/decryption round trip | Passed. |
| Modified ciphertext authentication | Rejected correctly. |
| Wrong password | Rejected correctly. |
| Python-to-PowerShell 7 and reverse encrypted format compatibility | Passed. |
| Windows OpenCode credential lifecycle simulation | Provider file encrypted; MCP file remained in plaintext, confirming R2. |
| Mid-write failure injection | Destroyed the previous encrypted copy, confirming R3. |
| Indented TOML table reproduction | Root setting absent after rewriting, confirming R6. |
| Plaintext/encrypted coexistence predicate | Plaintext found but leftovers false, confirming R7's branch condition. |
| Dummy provider API-key inheritance | Host key retained, confirming R1. |
| Mocked Keychain read error | Returned missing-item result, confirming R5. |

PowerShell 5.1 execution was attempted twice, including once without an inherited `PSModulePath`. Both attempts failed because the host could not load `Microsoft.PowerShell.Security` for `ConvertTo-SecureString`. This is an environment limitation, not evidence of a project defect; this review does not certify PowerShell 5.1 runtime compatibility. Native Linux/macOS execution, shell syntax validation with POSIX `sh`, real assistant authentication, full package downloads, and concurrent credential-store execution were not performed.

## Suggested implementation order (original review)

1. Establish credential environment policy and cover Windows OpenCode MCP credentials.
2. Add private atomic writes, recoverable save behavior, and exclusive session/store locks.
3. Make Keychain failures explicit and propagate protection failures through exit codes.
4. Correct TOML rewriting and encrypt-only recovery.
5. Make installation promotion and rollback recoverable; validate peak disk usage.
6. Commit regression tests and run native integration checks, then update the security claims in the guides.

## Folder-only hardening follow-up — 2026-09-30

The findings and reproductions above describe the original checkout. The user subsequently required folder-only credential management and explicitly chose to block Antigravity's native-keyring login. The implementation now follows the policy in [ISOLATION.md](ISOLATION.md); it does not establish an OS sandbox.

| Finding | Current status |
| --- | --- |
| R1: inherited host credentials | Fresh allowlisted assistant and download environments exclude host API keys, tokens, proxies, agent sockets, and startup hooks. Standard cloud, Git, home, runtime, and temporary paths point into the portable. |
| R2: Windows OpenCode MCP tokens | Both provider and MCP token files are protected in a versioned bundle; legacy encrypted provider-only files remain readable. Codex also protects its separate MCP token file and forces both credential stores to `file`. |
| R3: destructive credential saves | Private sibling files are flushed and replaced atomically. An injected replacement failure preserves the previous encrypted file. Filesystem-specific behavior and sudden removal still require native validation. |
| R4: concurrent credential sessions | Exclusive per-assistant session locks reject a second credential session. Installer coordination with these locks and interrupted update promotion still need further work. |
| R5: native-store error handling | Production native-store access is disabled. Antigravity sessions are blocked; legacy helpers/data are preserved without automatic host-store recovery. |
| R6: configuration rewriting | Indented table boundaries are recognized and Codex CLI overrides enforce file stores. The lightweight TOML rewriter is still not a complete parser, particularly for multiline strings. |
| R7: encrypt-only recovery | Newer plaintext is preserved and included even when an encrypted predecessor exists. Known provider/MCP files are covered. |
| R8: installation recovery and space | Staging and verification profiles now remain under the installation. Space estimates include staging and replacement copies. Full rollback after interrupted promotion remains open. |
| R9: cleanup exit codes | Python cleanup and Windows Claude, Codex, and OpenCode normal-session cleanup report protection failures. Cancellation/recovery branches still merit broader failure-injection coverage. |

Additional controls reject external state paths and existing symlinks/junctions before managed access, isolate Python startup with `-I -S -B`, remove environment-controlled executable replacements, and stop on non-executable POSIX drives instead of copying programs into host temporary storage. Managed sessions default to a portable working directory.

Validation: all **14 regression tests passed** using disposable installations and simulated assistants, including Windows provider/MCP credential restoration, wrong-password rejection, atomic-save failure recovery, concurrent session rejection, linked/external path rejection, child environments, actual temporary-file locations, disabled host-Keychain access, and Linux/macOS source parity. These tests do not certify the behavior of downloaded native assistants. The final Windows download-environment and Claude cleanup adjustments received parser checks and a repeated Windows child-environment regression.

Remaining scope includes actual assistant integration and filesystem/process tracing on all three platforms, PowerShell 5.1 runtime validation, installer rollback, complete TOML parsing, persisted sign-out semantics, and OS access restrictions. No assistant packages were installed or upgraded as part of this hardening. Current upstream version details in the original review are a dated snapshot, not a completed update.

## Follow-up review — 2026-10-16

Reviewed the hardened launchers and installers against the **real** assistant programs on Windows (Claude Code 2.1.292, Codex 0.163.0, OpenCode 1.19.3, Antigravity 1.4.0, installed from the official sources by `windows/instalar.ps1`), in addition to the regression suite.

### Confirmed working

- Real installation and verification from the internet; all four programs start through their launchers with the allowlisted environment.
- Real commands through the launchers: `claude --version`, `claude mcp list`, `claude doctor`, `codex login status`, `codex exec`, `opencode auth list`, and an actual `opencode run` answer (free OpenCode model) all worked; their state stayed in the portable.
- Host profile watch during those runs: no file under the user's `.claude.json`, `.codex`, `.local/share/opencode`, `.config/opencode`, `.gemini`, `.aws`, `.gitconfig`, or the matching `AppData` folders was written by the portable. (Changes seen there came from the user's own native Codex/Claude sessions and from a background process that touches the native OpenCode database every 60 seconds, independent of the portable.)
- Windows PowerShell 5.1 runtime: the launchers run, save, encrypt, and decrypt correctly with a normal 5.1 environment. The earlier `Microsoft.PowerShell.Security` failure was specific to the review environment.

### Findings and fixes

| ID | Severity | Finding | Fix |
| --- | --- | --- | --- |
| R10 | High | The Windows Claude, Codex, and Antigravity launchers used a `param()` block, so PowerShell accepted abbreviations of launcher options: `claude -p "…"` failed ("cannot convert … to SecureString" for `-Password`), and Claude's `-c`/`-d` and Codex's `-p`/`-c` were taken as `-CmdArgs`/`-DataDir`/`-PortablePassword`. Present before the hardening. | Launcher options are parsed by hand (as in the OpenCode launcher): only the exact names `-DataDir`, `-Password` (and `-PortablePassword` in Codex), `-EncryptOnly`, and `-Workspace` belong to the launcher; everything else reaches the assistant unchanged. Verified with the real Claude (`-p`, `-d`) and Codex (`-c`, `-p`). |
| R11 | Medium | The Codex launchers (Windows and Linux/macOS) appended `-c cli_auth_credentials_store='file' -c mcp_oauth_credentials_store='file'` after the user's arguments. With the real Codex, `codex mcp add NAME -- npx PACKAGE` stored `args = ["PACKAGE", "-c", "cli_auth_credentials_store='file'"]`, corrupting the MCP server configuration. | The overrides are global options and now precede the user's arguments (and `-C <workspace>`). Verified with the real Codex: `args = ["PACKAGE"]`. |
| R12 | Low | The installers' verification reported Antigravity as "sin credenciales: pedirá iniciar sesión", and their final message suggested starting it, although its sessions are blocked. | Antigravity is reported as installed with sign-in blocked (`--version`/`--help` only) and is no longer suggested as a starting point. |
| R13 | Low | Empty state folders `linux/claude/data/claude` left in the project by an earlier run. | Removed; the project contains scripts only. |

Regression tests added: `test_windows_assistant_flags_are_not_taken_by_launchers` (real launchers with a simulated program, with and without `-Workspace`) and `test_python_codex_overrides_precede_user_arguments`. The suite now has **16 tests, all passing**.

Still open: native Linux/macOS runs with the real programs, installer rollback after an interrupted promotion, a complete TOML parser, and an OS-level isolation layer (see ISOLATION.md).
