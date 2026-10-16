# ============================================================
#  opencode - portable launcher (PowerShell + auth protection)
#
#  Everything (data, config, cache) stays inside this folder.
#  Credentials are never taken from the computer: connect a provider
#  inside the portable (/connect or `auth login`); when opencode exits
#  the launcher asks for the common portable password (see
#  ..\portable-crypto.ps1) and keeps auth.json ENCRYPTED on disk as
#  auth.json.enc (authenticated AES-256-CBC). Later starts ask for the
#  password; the file is decrypted only for the duration of the
#  session and re-encrypted when opencode exits.
#
#  Test/debug options (not needed for normal use):
#    -DataDir <dir>     override the data directory
#    -Password <pw>     supply the password programmatically (plaintext)
#    -EncryptOnly       only encrypt an existing plain auth.json, exit
#    -Workspace <name>  skip the menu and open/create sesiones\<name> directly
#
#  NOTE: there is intentionally no param() block. PowerShell's parameter
#  binder would mis-handle opencode's own flags (e.g. -c can abbreviate
#  -CmdArgs, -p -> -Password): short flags would be swallowed or raise
#  "Missing an argument". Instead $args is parsed manually below and every
#  token that is not one of the launcher options above is forwarded to
#  opencode.exe verbatim.
# ============================================================

$ErrorActionPreference = 'Stop'

# --- parse launcher options manually; everything else -> $CmdArgs ----------
$DataDir    = ''
$Password   = $null
$EncryptOnly = $false
$Workspace  = ''
$CmdArgs    = [System.Collections.Generic.List[string]]::new()

for ($i = 0; $i -lt $args.Count; $i++) {
  $token = $args[$i]
  $name  = $token -replace '^-+', ''
  if ($token.StartsWith('-') -and $name -in @('DataDir', 'Password', 'EncryptOnly', 'Workspace')) {
    if ($name -eq 'EncryptOnly') {
      $EncryptOnly = $true
    } else {
      $i++
      if ($i -ge $args.Count) {
        Write-Error "[opencode] Falta el valor para: $token"
        exit 1
      }
      $value = $args[$i]
      if ($name -eq 'Password') {
        $Password = ConvertTo-SecureString $value -AsPlainText -Force
      } elseif ($name -eq 'DataDir') {
        $DataDir = $value
      } else {
        $Workspace = $value
      }
    }
  } else {
    $CmdArgs.Add($token)
  }
}

$root = $PSScriptRoot
if ([string]::IsNullOrEmpty($root)) { $root = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$cryptoPath = Join-Path (Split-Path -Parent $root) 'portable-crypto.ps1'
if (-not (Test-Path -LiteralPath $cryptoPath -PathType Leaf)) { throw "Missing shared credential module: $cryptoPath" }
. $cryptoPath
Assert-PortableTree -Root $root
if ([string]::IsNullOrEmpty($DataDir)) { $DataDir = Join-Path $root 'data' }
Assert-PortablePath -Root $root -Path $DataDir
$portableSessionLock = Open-PortableSessionLock -Root $root
try {

$bin      = Join-Path $root 'bin\opencode.exe'
$authDir  = Join-Path $DataDir 'opencode'
$auth     = Join-Path $authDir 'auth.json'
$authEnc  = Join-Path $authDir 'auth.json.enc'
$secretPaths = @($auth, (Join-Path $authDir 'mcp-auth.json'))

if (-not (Test-Path -LiteralPath $bin)) {
  [Console]::Error.WriteLine("[opencode] Falta el programa ($bin).")
  [Console]::Error.WriteLine("[opencode] Descargalo ejecutando actualizar.cmd en la carpeta del portable (necesita internet).")
  exit 1
}

# Redirect opencode data/config/cache to the portable folder
$env:XDG_DATA_HOME   = Join-Path $root 'data'
$env:XDG_CONFIG_HOME = Join-Path $root 'config'
$env:XDG_CACHE_HOME  = Join-Path $root 'cache'
$env:OPENCODE_DISABLE_AUTOUPDATE = '1'

function ConvertTo-OcEncrypted { param([byte[]]$Plain, [SecureString]$Sec); Protect-PortableData $Plain $Sec 'PORTOC02' }
function ConvertFrom-OcEncrypted { param([byte[]]$Blob, [SecureString]$Sec); Unprotect-PortableData $Blob $Sec 'PORTOC02' }

# Read the password from -Password or the environment now, so the
# variables are gone before opencode starts.
$envPassword = Pop-PortableEnvPassword -Names @('OPENCODE_PASSWORD')
if ($null -eq $Password) { $Password = $envPassword }
Set-PortableChildEnvironment -HomeDirectory $DataDir
$env:XDG_DATA_HOME = $DataDir
$env:XDG_CONFIG_HOME = Join-Path $root 'config'
$env:XDG_CACHE_HOME = Join-Path $root 'cache'
$env:OPENCODE_DISABLE_AUTOUPDATE = '1'

# Encrypt the plain auth.json and wipe it. On the first start there is
# no password yet: it is asked here, after a provider has been connected.
# If encryption fails the plain file is kept (and encrypted on the next
# start) rather than lost.
function Protect-Auth {
  $present = @($secretPaths | Where-Object { Test-Path -LiteralPath $_ })
  if ($present.Count -eq 0) { return }
  try {
    if ($null -eq $script:sessionPass) {
      Write-Host '[opencode] Guardando las credenciales en el portable.'
      $script:sessionPass = Get-PortablePassword -Tool 'opencode' -Provided $Password -ForNewCredentials
    }
    $files = [ordered]@{}
    foreach ($path in $present) { $files[[IO.Path]::GetFileName($path)] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) }
    $bundle = [ordered]@{ _portable_format = 'opencode-credentials-v1'; files = $files }
    $plain = [Text.Encoding]::UTF8.GetBytes(($bundle | ConvertTo-Json -Depth 6))
    $enc = ConvertTo-OcEncrypted -Plain $plain -Sec $script:sessionPass
    Write-PortablePrivateBytes $authEnc $enc
    foreach ($path in $present) { Remove-Item -LiteralPath $path -Force }
    return $true
  } catch {
    Write-Warning "[opencode] No se pudieron cifrar las credenciales: $($_.Exception.Message)"
    Write-Warning "[opencode] Siguen en claro en $auth; se cifraran en el proximo arranque."
    return $false
  }
}

function Restore-OcCredentials {
  param([byte[]]$Plain)
  $bundle = [Text.Encoding]::UTF8.GetString($Plain) | ConvertFrom-Json
  if ($bundle._portable_format -eq 'opencode-credentials-v1') {
    foreach ($property in $bundle.files.PSObject.Properties) {
      if ($property.Name -notin @('auth.json', 'mcp-auth.json')) { throw 'Invalid portable OpenCode credential path.' }
      $path = Join-Path $authDir $property.Name
      Assert-PortablePath -Root $root -Path $path
      if (-not (Test-Path -LiteralPath $path)) { Write-PortablePrivateBytes $path ([Convert]::FromBase64String([string]$property.Value)) }
    }
  } elseif (-not (Test-Path -LiteralPath $auth)) {
    # Legacy encrypted files contain only the raw provider auth.json.
    Write-PortablePrivateBytes $auth $Plain
  }
}

function Get-OcLock {
  return Get-Item -LiteralPath ($bin + '.lock') -ErrorAction SilentlyContinue
}

function Select-Workspace {
  param([string]$SesionesRoot)

  if (-not (Test-Path -LiteralPath $SesionesRoot)) {
    New-Item -ItemType Directory -Path $SesionesRoot -Force | Out-Null
  }

  $existing = @(
    Get-ChildItem -LiteralPath $SesionesRoot -Directory -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      Select-Object -ExpandProperty Name
  )

  function Read-Name {
    while ($true) {
      $name = (Read-Host -Prompt 'Nombre del espacio de trabajo').Trim()
      if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Host '  El nombre no puede estar vacio.'
        continue
      }
      if ($name -match '[\\/:*?"<>|]') {
        Write-Host '  El nombre no puede contener estos caracteres: \ / : * ? " < > |'
        continue
      }
      $target = Join-Path $SesionesRoot $name
      if (Test-Path -LiteralPath $target) {
        return $target
      }
      New-Item -ItemType Directory -Path $target -Force | Out-Null
      Write-Host "  Carpeta creada: sesiones\$name"
      return $target
    }
  }

  Write-Host ''
  Write-Host '[opencode] Espacios de trabajo (sesiones\):'
  Write-Host ''

  if ($existing.Count -eq 0) {
    Write-Host '  No hay espacios de trabajo. Se creara uno nuevo.'
    return Read-Name
  }

  for ($i = 0; $i -lt $existing.Count; $i++) {
    Write-Host ('  {0}) {1}' -f ($i + 1), $existing[$i])
  }
  $newIdx = $existing.Count + 1
  Write-Host ('  {0}) Crear nueva sesion' -f $newIdx)
  Write-Host ''
  Write-Host '  Enter en blanco = salir sin abrir opencode'
  Write-Host ''

  while ($true) {
    $input = (Read-Host -Prompt 'Seleccion').Trim()
    if ([string]::IsNullOrWhiteSpace($input)) {
      return $null
    }
    $parsed = 0
    if ([int]::TryParse($input, [ref]$parsed)) {
      if ($parsed -ge 1 -and $parsed -le $existing.Count) {
        return (Join-Path $SesionesRoot $existing[$parsed - 1])
      }
      if ($parsed -eq $newIdx) {
        return Read-Name
      }
    }
    Write-Host '  Opcion no valida. Intenta de nuevo.'
  }
}

$sessionPass = $null

# Restore the previous bundle before merging newer plaintext credentials.
if (Test-Path -LiteralPath $authEnc) {
  try {
    $sessionPass = Get-PortablePassword -Tool 'opencode' -Provided $Password
    $plain = ConvertFrom-OcEncrypted -Blob ([IO.File]::ReadAllBytes($authEnc)) -Sec $sessionPass
    Restore-OcCredentials -Plain $plain
    Register-PortablePassword $sessionPass
  } catch {
    [Console]::Error.WriteLine("[opencode] Could not restore portable credentials: $($_.Exception.Message)")
    exit 2
  }
}
if ($EncryptOnly) {
  $result = Protect-Auth
  if ($result -eq $false) { exit 3 }
  exit 0
}
if (@($secretPaths | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0 -and -not (Test-Path -LiteralPath $authEnc)) {
  if ((Protect-Auth) -eq $false) { exit 3 }
  $plain = ConvertFrom-OcEncrypted -Blob ([IO.File]::ReadAllBytes($authEnc)) -Sec $sessionPass
  Restore-OcCredentials -Plain $plain
}

# --- select workspace & run opencode ------------------------------------
$sessionDir = $null
$sesionesRoot = Join-Path $root 'sesiones'

if (-not [string]::IsNullOrEmpty($Workspace)) {
  if ($Workspace -match '[\\/:*?"<>|]' -or [string]::IsNullOrWhiteSpace($Workspace) -or $Workspace -in @('.', '..')) {
    [Console]::Error.WriteLine("[opencode] Nombre de workspace invalido: $Workspace")
    $null = Protect-Auth
    exit 1
  }
  $sessionDir = Join-Path $sesionesRoot $Workspace
  if (-not (Test-Path -LiteralPath $sessionDir)) {
    New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
    Write-Host "[opencode] Carpeta creada: sesiones\$Workspace"
  }
  Write-Host "[opencode] Abriendo sesion en: $Workspace"
  Write-Host ''
} elseif ($CmdArgs.Count -eq 0) {
  $sessionDir = Select-Workspace -SesionesRoot $sesionesRoot
  if ($null -eq $sessionDir) {
    Write-Host '[opencode] Cancelado.'
    $null = Protect-Auth
    exit 0
  }
  Write-Host "[opencode] Abriendo sesion en: $(Split-Path $sessionDir -Leaf)"
  Write-Host ''
}

$code = 0
try {
  if ($null -ne $sessionDir) {
    Push-Location $sessionDir
    try { & $bin @($CmdArgs) } finally { Pop-Location }
  } else {
    Push-Location $root
    try { & $bin @($CmdArgs) } finally { Pop-Location }
  }
  if ($null -ne $LASTEXITCODE) { $code = $LASTEXITCODE } else { $code = 0 }
} finally {
  if ((Protect-Auth) -eq $false) { $code = 3 }
}

exit $code

} finally { $portableSessionLock.Dispose() }
