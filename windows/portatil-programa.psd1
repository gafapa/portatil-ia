# Definition of the portable installation, used by instalar.ps1.
#
# The assistants' program files are downloaded from their official
# sources and verified against the published hash. Only the scripts listed
# here (launchers and the root scripts) are copied from the folder that
# contains instalar.ps1.
#
# Everything else in a portable is state (data, config, cache, sesiones,
# workspaces, credentials, portatil.passcheck, versiones.json) and is never
# overwritten.
#
# The x64 builds are used on purpose: the portable may be plugged into any
# PC, and x64 programs also run on Windows on ARM through emulation.
@{
  # Scripts at the root of the portatil folder.
  RootFiles = @(
    'portable-crypto.ps1'
    'portatil-programa.psd1'
    'instalar.cmd'
    'instalar.ps1'
    'actualizar.cmd'
    'README.md'
  )

  # Scripts of earlier versions of the portable that no longer exist and
  # are removed from the destination when it is updated.
  ObsoleteFiles = @(
    'actualizar.ps1'
  )

  # Per assistant, relative to its folder:
  #   Files         launcher scripts, copied from the instalar.ps1 folder
  #   Dirs          program folders, replaced exactly by the downloaded ones
  #   PackageFiles  loose program files that come in the download
  #   Exe           main executable, used to verify the installation
  #   Source        where the program is downloaded from
  #     Type  claude  downloads.claude.ai manifest (SHA-256)
  #           github  latest GitHub release asset (SHA-256 digest)
  #           agy     Antigravity CLI updater manifest (SHA-512)
  #     Extract  none: the download is Exe; zip/targz: archive unpacked
  #              into the folder named by Into (relative to the assistant)
  Tools = @{
    antigravity = @{
      Files        = @('antigravity.cmd', 'antigravity.ps1')
      Dirs         = @('bin')
      PackageFiles = @()
      Exe          = 'bin\agy.exe'
      Source       = @{
        Type     = 'agy'
        Manifest = 'https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/windows_amd64.json'
        Extract  = 'none'
      }
    }
    claude = @{
      Files        = @('claude.cmd', 'claude.ps1')
      Dirs         = @('bin')
      PackageFiles = @()
      Exe          = 'bin\claude.exe'
      Source       = @{
        Type     = 'claude'
        BaseUrl  = 'https://downloads.claude.ai/claude-code-releases'
        Channel  = 'stable'
        Platform = 'win32-x64'
        Extract  = 'none'
      }
    }
    codex = @{
      Files        = @('codex.cmd', 'codex.ps1')
      Dirs         = @('bin', 'codex-path', 'codex-resources')
      PackageFiles = @('codex-package.json')
      Exe          = 'bin\codex.exe'
      Source       = @{
        Type      = 'github'
        Repo      = 'openai/codex'
        Asset     = 'codex-package-x86_64-pc-windows-msvc.tar.gz'
        TagPrefix = 'rust-v'
        Extract   = 'targz'
        Into      = '.'
      }
    }
    oc = @{
      Files        = @('opencode.cmd', 'opencode.ps1')
      Dirs         = @('bin')
      PackageFiles = @()
      Exe          = 'bin\opencode.exe'
      Source       = @{
        Type      = 'github'
        Repo      = 'sst/opencode'
        # baseline: also runs on older CPUs without AVX2.
        Asset     = 'opencode-windows-x64-baseline.zip'
        TagPrefix = 'v'
        Extract   = 'zip'
        Into      = 'bin'
      }
    }
  }
}
