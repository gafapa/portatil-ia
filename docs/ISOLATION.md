# Authentication and storage isolation

This policy describes the current launchers, including the folder-only hardening added after the original review.

## Managed behavior

| Area | Current behavior |
| --- | --- |
| Host API keys and tokens | Not inherited. Child environments use an explicit allowlist, including exclusion of unknown provider variables. |
| Host authentication helpers and agent sockets | Not inherited. Global Git configuration is portable; system Git configuration is disabled. |
| Home and standard cloud profiles | Redirected inside the assistant folder: AWS, Boto, gcloud, Azure, Kubernetes, and Git. AWS EC2 metadata discovery is disabled. |
| Working directory | The chosen portable workspace, or the assistant folder when arguments are supplied. |
| Runtime and temporary files | `TEMP`, `TMP`, `TMPDIR`, `CLAUDE_CODE_TMPDIR`, and `XDG_RUNTIME_DIR` point inside the portable profile. |
| Installer staging and version-check profiles | Unique directories under `<installation>/.portable-tmp`; version checks run from their disposable portable profile. |
| Non-executable Linux drive | Startup stops. No program copy is made in host `/tmp` or a host runtime directory. |
| External or linked state paths | Rejected before managed credential/configuration access. Windows `-DataDir` cannot escape the assistant folder. |
| Credential sessions | An exclusive per-assistant lock prevents simultaneous credential restoration and cleanup. OS locks release after a process exits or crashes. |
| Credential saves | New data is written and flushed to a private sibling temporary file before replacing the previous encrypted file. Replacement failure preserves the previous file and leaves current plaintext for recovery. |
| Native host credential stores | Automatic inspection and shuttling are disabled. Antigravity OAuth sessions fail closed on all platforms. |

Codex uses explicit command-line overrides for both `cli_auth_credentials_store` and `mcp_oauth_credentials_store`, set to `file`. Its main authentication file and MCP `.credentials.json` are included in protection. Windows keeps the two files encrypted separately for backward compatibility. Linux/macOS keep them in the assistant bundle. Source: [OpenAI configuration schema](https://github.com/openai/codex/blob/main/codex-rs/core/config.schema.json) and [MCP credential storage](https://github.com/openai/codex/blob/main/codex-rs/rmcp-client/src/oauth.rs).

Windows OpenCode protects both `auth.json` and `mcp-auth.json` in a versioned encrypted bundle and can still restore the older raw-auth encrypted format. It preserves newer plaintext files when restoring an older encrypted bundle. Source for the MCP token file: [OpenCode MCP authentication](https://opencode.ai/docs/mcp-servers/).

macOS Claude uses only the token configured in the portable; it does not import `CLAUDE_CODE_OAUTH_TOKEN` from the host environment. The stored token is added after environment sanitization. The user must still avoid running `/login` inside Claude, because that command is handled by the upstream assistant and can use the native Keychain.

Python launcher entry points use `-I -S -B`: host Python environment settings and user/site startup customization are excluded, and imports do not create bytecode caches. The launchers explicitly load their own standard-library-only modules.

## Antigravity compatibility change

The previous implementation temporarily moved host credentials and placed portable tokens in Credential Manager or Keychain. That violates a requirement to keep credential management entirely inside the installation folder, even when the host entries are restored correctly. It is no longer used.

Google documents a Gemini API mode with `modelProvider: "gemini"` and a supplied `GEMINI_API_KEY`, avoiding an account session. That would require an explicitly configured portable key and can have different billing. The current launchers do not silently switch accounts to this mode or import a host key. Source: [Antigravity authentication](https://antigravity.google/docs/cli/install).

Existing encrypted Antigravity files and the legacy Windows recovery helper are preserved. The helper is no longer copied by the installer or called by the launcher/verifier. Existing host backup/pending entries are not automatically accessed; recovering them requires a separate explicit task.

## What these scripts cannot guarantee

This is authentication and default-path isolation, not an OS access-control boundary. Assistants and their tools execute with the current user's permissions and use host runtimes, system libraries, certificates, and essential OS services. They can deliberately read arbitrary accessible files, query other OS credential services, call cloud metadata endpoints, or write to an absolute path. Environment sanitization does not prevent that.

Third-party programs may also read machine-managed configuration or ignore redirected home/temp settings. Plugins, MCP servers, command-line flags, project configuration, authentication helpers explicitly configured in the portable, and browser-based authorization may introduce access beyond these defaults. A host browser can have an existing signed-in session. Config files containing manually embedded API keys are not automatically classified or encrypted by this project.

An absolute requirement that programs cannot access any host credentials or write anywhere outside the installation requires an OS sandbox, VM, container, or separate execution identity with restricted mounts/permissions and controlled OS-service access. A built-in assistant tool sandbox alone is insufficient to confine the assistant process itself.

Existing links are checked before launch; a malicious concurrent filesystem replacement still requires OS isolation to prevent races. Atomic replacement and flushing improve recovery, but cannot guarantee durability after sudden device removal. Filesystems without ACLs cannot protect decrypted files from other users who can access the drive.

## Verification and remaining work

Run `python -B -m unittest discover -s tests -v` from the project root. Tests use dummy secrets, disposable copies, simulated assistants, and injected failures. They check child environments, working and temporary directories, portable-token precedence, external path rejection, session locks, no-exec behavior, host-Keychain refusal, atomic-save failure recovery, Linux/macOS parity, and Windows provider/MCP credential lifecycle.

The current changes still need native integration runs with the actual assistant binaries on Windows, Linux, and macOS, filesystem tracing of the full process tree, and real macOS token setup. PowerShell 5.1 runtime validation remains blocked by the security-module loading failure recorded in the review. Until those checks and an OS isolation layer are in place, the project must not claim that third-party programs never read or write any host data.
