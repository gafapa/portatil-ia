# ============================================================
#  Codex portable launcher for Windows.
#
#  CODEX_HOME is redirected into this folder. Credentials are never
#  taken from the computer: sign in inside the portable (codex login);
#  when Codex exits, the launcher asks for the common portable password
#  (see ..\portable-crypto.ps1) and encrypts auth.json at rest with
#  authenticated AES-256-CBC. It is available in plaintext only while
#  Codex runs.
# ============================================================

$ErrorActionPreference = 'Stop'

# Launcher options are parsed by hand. A param() block would let
# PowerShell accept abbreviations, so the assistant's own flags (-p, -c,
# -d, ...) would be taken as launcher options. Only these exact names are
# launcher options; every other argument goes to the assistant unchanged.
$DataDir = ''; $Password = $null; $EncryptOnly = $false; $Workspace = ''
$argumentList = [System.Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $args.Count; $i++) {
  $token = [string]$args[$i]
  $optionName = $token -replace '^-+', ''
  if ($token.StartsWith('-') -and $optionName -in @('DataDir', 'PortablePassword', 'Password', 'EncryptOnly', 'Workspace')) {
    if ($optionName -eq 'EncryptOnly') { $EncryptOnly = $true; continue }
    $i++
    if ($i -ge $args.Count) { [Console]::Error.WriteLine("[codex] Falta el valor para: $token"); exit 1 }
    if ($optionName -in @('PortablePassword', 'Password')) { $Password = ConvertTo-SecureString ([string]$args[$i]) -AsPlainText -Force }
    elseif ($optionName -eq 'DataDir') { $DataDir = [string]$args[$i] }
    else { $Workspace = [string]$args[$i] }
  } else {
    $argumentList.Add($token)
  }
}
$CmdArgs = [string[]]$argumentList.ToArray()
$PortablePassword = $Password

$root = $PSScriptRoot
if ([string]::IsNullOrEmpty($root)) {
  $root = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
$cryptoPath = Join-Path (Split-Path -Parent $root) 'portable-crypto.ps1'
if (-not (Test-Path -LiteralPath $cryptoPath -PathType Leaf)) { throw "Missing shared credential module: $cryptoPath" }
. $cryptoPath
Assert-PortableTree -Root $root
if ([string]::IsNullOrEmpty($DataDir)) {
  $DataDir = Join-Path $root 'data\codex'
}
Assert-PortablePath -Root $root -Path $DataDir
$DataDir = [IO.Path]::GetFullPath($DataDir)
$portableSessionLock = Open-PortableSessionLock -Root $root
try {

$binaryPath = Join-Path $root 'bin\codex.exe'
$codeModeHostPath = Join-Path $root 'bin\codex-code-mode-host.exe'
$commandRunnerPath = Join-Path $root 'codex-resources\codex-command-runner.exe'
$sandboxSetupPath = Join-Path $root 'codex-resources\codex-windows-sandbox-setup.exe'
$ripgrepPath = Join-Path $root 'codex-path\rg.exe'
$packageManifestPath = Join-Path $root 'codex-package.json'
$authPath = Join-Path $DataDir 'auth.json'
$encryptedAuthPath = Join-Path $DataDir 'auth.json.enc'
$mcpAuthPath = Join-Path $DataDir '.credentials.json'
$encryptedMcpAuthPath = $mcpAuthPath + '.enc'
$credentialPairs = @(
  @{ Plain = $authPath; Encrypted = $encryptedAuthPath },
  @{ Plain = $mcpAuthPath; Encrypted = $encryptedMcpAuthPath }
)
$workspaceRoot = Join-Path $root 'workspaces'

if (-not (Test-Path -LiteralPath $binaryPath)) {
  [Console]::Error.WriteLine("[codex] Falta el programa ($binaryPath).")
  [Console]::Error.WriteLine("[codex] Descargalo ejecutando actualizar.cmd en la carpeta del portable (necesita internet).")
  exit 1
}
if (-not (Test-Path -LiteralPath $codeModeHostPath)) {
  Write-Error "[codex] Could not find the required code-mode host at: $codeModeHostPath"
  exit 1
}
$requiredSupportFiles = @($commandRunnerPath, $sandboxSetupPath, $ripgrepPath, $packageManifestPath)
foreach ($requiredSupportFile in $requiredSupportFiles) {
  if (-not (Test-Path -LiteralPath $requiredSupportFile -PathType Leaf)) {
    Write-Error "[codex] Could not find a required standalone package file at: $requiredSupportFile"
    exit 1
  }
}

New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
$env:CODEX_HOME = $DataDir

# Reject overrides before credentials are decrypted. Options after -- belong
# to a nested command and must pass through unchanged.
$reservedSettings = @('cli_auth_credentials_store', 'mcp_oauth_credentials_store', 'sqlite_home', 'log_dir', 'codex_home')
for ($index = 0; $index -lt $CmdArgs.Count; $index++) {
  $argument = $CmdArgs[$index]
  if ($argument -eq '--') { break }
  $value = $null
  if ($argument -in @('-c', '--config')) {
    $index++
    if ($index -lt $CmdArgs.Count) { $value = $CmdArgs[$index] }
  } elseif ($argument.StartsWith('--config=')) { $value = $argument.Substring(9) }
  elseif ($argument.StartsWith('-c') -and $argument.Length -gt 2) { $value = $argument.Substring(2) }
  if ($null -ne $value) {
    $key = ($value -split '=', 2)[0].Replace('"', '').Replace("'", '').Trim()
    foreach ($part in ($key -split '\.')) {
      if ($part.Trim() -in $reservedSettings) { throw "Portable Codex storage settings cannot be overridden: $key" }
    }
  }
}
# JSON strings are also TOML basic strings, including escaped drive paths.
$portableCodexOptions = @('-c', 'cli_auth_credentials_store="file"', '-c', 'mcp_oauth_credentials_store="file"',
  '-c', ('sqlite_home=' + (ConvertTo-Json -InputObject ([IO.Path]::GetFullPath($DataDir)) -Compress)),
  '-c', ('log_dir=' + (ConvertTo-Json -InputObject (Join-Path ([IO.Path]::GetFullPath($DataDir)) 'logs') -Compress)))

function ConvertTo-EncryptedAuth { param([byte[]]$Plaintext, [SecureString]$SecurePassword); Protect-PortableData $Plaintext $SecurePassword 'PORTCX02' }
function ConvertFrom-EncryptedAuth { param([byte[]]$Blob, [SecureString]$SecurePassword); Unprotect-PortableData $Blob $SecurePassword 'PORTCX02' }

# Read the password from -PortablePassword or the environment now, so the
# variables are gone before Codex starts.
$envPassword = Pop-PortableEnvPassword -Names @('CODEX_PORTABLE_PASSWORD')
if ($null -eq $PortablePassword) { $PortablePassword = $envPassword }
Set-PortableChildEnvironment -HomeDirectory $DataDir
$env:CODEX_HOME = $DataDir
$env:CODEX_SQLITE_HOME = $DataDir
$env:PATH = (Join-Path $root 'codex-path') + [IO.Path]::PathSeparator + $env:PATH

# Encrypts auth.json and removes the plaintext. On the first save the
# common password is asked here. The plaintext is only removed once the
# encrypted copy has been written.
function Protect-AuthFile {
  param([SecureString]$SecurePassword)

  $present = @($credentialPairs | Where-Object { Test-Path -LiteralPath $_.Plain })
  if ($present.Count -eq 0) { return $SecurePassword }
  if ($null -eq $SecurePassword) {
    Write-Host '[codex] Saving the credentials in the portable.'
    $SecurePassword = Get-PortablePassword -Tool 'codex' -Provided $PortablePassword -ForNewCredentials
  }

  foreach ($pair in $present) {
    $encrypted = ConvertTo-EncryptedAuth -Plaintext ([IO.File]::ReadAllBytes($pair.Plain)) -SecurePassword $SecurePassword
    Write-PortablePrivateBytes $pair.Encrypted $encrypted
    Remove-Item -LiteralPath $pair.Plain -Force
  }
  return $SecurePassword
}

function Read-WorkspaceName {
  param([string]$Root)

  while ($true) {
    $name = (Read-Host -Prompt 'Workspace name').Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
      Write-Host '  The name cannot be empty.'
      continue
    }
    if ($name -match '[\\/:*?"<>|]') {
      Write-Host '  The name contains a character forbidden by Windows.'
      continue
    }
    $target = Join-Path $Root $name
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    return $target
  }
}

function Select-Workspace {
  param([string]$Root)

  New-Item -ItemType Directory -Path $Root -Force | Out-Null
  $existing = @(
    Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      Select-Object -ExpandProperty Name
  )

  Write-Host ''
  Write-Host '[codex] Workspaces:'
  Write-Host ''
  if ($existing.Count -eq 0) {
    Write-Host '  No workspaces exist yet. Create the first one.'
    return Read-WorkspaceName -Root $Root
  }

  for ($index = 0; $index -lt $existing.Count; $index++) {
    Write-Host ('  {0}) {1}' -f ($index + 1), $existing[$index])
  }
  $newIndex = $existing.Count + 1
  Write-Host ('  {0}) Create a new workspace' -f $newIndex)
  Write-Host ''
  Write-Host '  Press Enter without a value to cancel.'

  while ($true) {
    $selection = (Read-Host -Prompt 'Selection').Trim()
    if ([string]::IsNullOrWhiteSpace($selection)) { return $null }
    $parsed = 0
    if ([int]::TryParse($selection, [ref]$parsed)) {
      if ($parsed -ge 1 -and $parsed -le $existing.Count) {
        return Join-Path $Root $existing[$parsed - 1]
      }
      if ($parsed -eq $newIndex) {
        return Read-WorkspaceName -Root $Root
      }
    }
    Write-Host '  Invalid selection. Try again.'
  }
}

$sessionPassword = $null
if (Test-Path -LiteralPath $encryptedAuthPath) {
  try {
    $sessionPassword = Get-PortablePassword -Tool 'codex' -Provided $PortablePassword
    $plaintext = ConvertFrom-EncryptedAuth `
      -Blob ([IO.File]::ReadAllBytes($encryptedAuthPath)) `
      -SecurePassword $sessionPassword
  } catch {
    [Console]::Error.WriteLine("[codex] Credentials could not be decrypted: $($_.Exception.Message)")
    exit 2
  }
  Register-PortablePassword $sessionPassword
  if (Test-Path -LiteralPath $authPath) {
    # Left by a session that ended abruptly: newer than the encrypted copy.
    # Keep it; it is encrypted on exit.
    Write-Host '[codex] Keeping newer credentials left by an earlier session.'
  } else {
    Write-PortablePrivateBytes $authPath $plaintext
  }
  Set-PortableFileAcl -Path $authPath
} elseif (Test-Path -LiteralPath $authPath) {
  # Left in the clear by an interrupted first save.
  Write-Host '[codex] Found unencrypted credentials from a previous session.'
  try {
    $sessionPassword = Protect-AuthFile -SecurePassword $null
  } catch {
    [Console]::Error.WriteLine("[codex] Credentials could not be secured: $($_.Exception.Message)")
    exit 3
  }
  if ($EncryptOnly) {
    Write-Host '[codex] Credentials encrypted. Codex was not started.'
    exit 0
  }
  $plaintext = ConvertFrom-EncryptedAuth `
    -Blob ([IO.File]::ReadAllBytes($encryptedAuthPath)) `
    -SecurePassword $sessionPassword
  Write-PortablePrivateBytes $authPath $plaintext
  Set-PortableFileAcl -Path $authPath
} elseif ($CmdArgs.Count -eq 0) {
  Write-Host '[codex] This portable has no credentials yet: sign in when Codex asks.'
  Write-Host '[codex] On exit you will be asked for the portable password to store them encrypted.'
}

# MCP tokens remain portable and are protected separately for compatibility.
if (Test-Path -LiteralPath $encryptedMcpAuthPath) {
  try {
    if ($null -eq $sessionPassword) { $sessionPassword = Get-PortablePassword -Tool 'codex' -Provided $PortablePassword }
    $mcpPlain = ConvertFrom-EncryptedAuth -Blob ([IO.File]::ReadAllBytes($encryptedMcpAuthPath)) -SecurePassword $sessionPassword
    if (-not (Test-Path -LiteralPath $mcpAuthPath)) { Write-PortablePrivateBytes $mcpAuthPath $mcpPlain }
  } catch { [Console]::Error.WriteLine('[codex] Could not restore portable MCP credentials.'); exit 2 }
}

if ($EncryptOnly) {
  try { $null = Protect-AuthFile -SecurePassword $sessionPassword }
  catch { [Console]::Error.WriteLine('[codex] Could not secure portable credentials.'); exit 3 }
  exit 0
}

$workspacePath = $null
if (-not [string]::IsNullOrWhiteSpace($Workspace)) {
  if ($Workspace -match '[\\/:*?"<>|]' -or $Workspace -in @('.', '..')) {
    [Console]::Error.WriteLine("[codex] Invalid workspace name: $Workspace")
    if (Test-Path -LiteralPath $authPath) { $null = Protect-AuthFile -SecurePassword $sessionPassword }
    exit 1
  }
  $workspacePath = Join-Path $workspaceRoot $Workspace
  New-Item -ItemType Directory -Path $workspacePath -Force | Out-Null
} elseif ($CmdArgs.Count -eq 0) {
  $workspacePath = Select-Workspace -Root $workspaceRoot
}

$exitCode = 0
$commandCompleted = $false
try {
  if ($null -ne $workspacePath) {
    Push-Location $workspacePath
    try { & $binaryPath @portableCodexOptions -C $workspacePath @CmdArgs } finally { Pop-Location }
  } elseif ($CmdArgs.Count -gt 0) {
    Push-Location $root
    try { & $binaryPath @portableCodexOptions @CmdArgs } finally { Pop-Location }
  }
  if ($null -ne $LASTEXITCODE) { $exitCode = $LASTEXITCODE }
  $commandCompleted = $true
} finally {
  # Persist successful logout instead of resurrecting the encrypted predecessor.
  if ($commandCompleted -and $exitCode -eq 0) {
    foreach ($pair in $credentialPairs) {
      if (-not (Test-Path -LiteralPath $pair.Plain) -and (Test-Path -LiteralPath $pair.Encrypted)) {
        Remove-Item -LiteralPath $pair.Encrypted -Force
      }
    }
  }
  if (@($credentialPairs | Where-Object { Test-Path -LiteralPath $_.Plain }).Count -gt 0) {
    try {
      $sessionPassword = Protect-AuthFile -SecurePassword $sessionPassword
      Write-Host '[codex] Credentials secured.'
    } catch {
      Write-Warning "[codex] Credentials could not be secured: $($_.Exception.Message)"
      Write-Warning "[codex] Plaintext credentials remain at: $authPath"
      $exitCode = 3
    }
  }
}

exit $exitCode

} finally { $portableSessionLock.Dispose() }
