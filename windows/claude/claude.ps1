# ============================================================
#  Claude Code - portable launcher (PowerShell + auth protection)
#
#  Everything (config, sessions, projects, cache) stays inside this
#  folder via CLAUDE_CONFIG_DIR. Credentials are never taken from the
#  computer: on the first start you sign in with /login, and when
#  Claude Code exits the launcher asks for the portable password and
#  stores .credentials.json ENCRYPTED as .credentials.json.enc
#  (authenticated AES-256-CBC, key derived from the password with
#  PBKDF2). Later starts ask for the password, decrypt the file only
#  for the session and re-encrypt it on exit.
#
#  The password is common to the four portable assistants
#  (see ..\portable-crypto.ps1).
#
#  Test/debug options (not needed for normal use):
#    -DataDir <dir>     override the data directory
#    -Password <text>   supply the password programmatically
#    -EncryptOnly       only encrypt an existing plain .credentials.json, exit
#    -Workspace <name>  skip the menu and open/create sesiones\<name> directly
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
  if ($token.StartsWith('-') -and $optionName -in @('DataDir', 'Password', 'EncryptOnly', 'Workspace')) {
    if ($optionName -eq 'EncryptOnly') { $EncryptOnly = $true; continue }
    $i++
    if ($i -ge $args.Count) { [Console]::Error.WriteLine("[claude] Falta el valor para: $token"); exit 1 }
    if ($optionName -in @('Password')) { $Password = ConvertTo-SecureString ([string]$args[$i]) -AsPlainText -Force }
    elseif ($optionName -eq 'DataDir') { $DataDir = [string]$args[$i] }
    else { $Workspace = [string]$args[$i] }
  } else {
    $argumentList.Add($token)
  }
}
$CmdArgs = [string[]]$argumentList.ToArray()

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

$bin       = Join-Path $root 'bin\claude.exe'
$configDir = Join-Path $DataDir 'claude'
$auth      = Join-Path $configDir '.credentials.json'
$authEnc   = Join-Path $configDir '.credentials.json.enc'

if (-not (Test-Path -LiteralPath $bin)) {
  [Console]::Error.WriteLine("[claude] Falta el programa ($bin).")
  [Console]::Error.WriteLine("[claude] Descargalo ejecutando actualizar.cmd en la carpeta del portable (necesita internet).")
  exit 1
}
if (-not (Test-Path -LiteralPath $configDir)) {
  New-Item -ItemType Directory -Path $configDir -Force | Out-Null
}

function ConvertTo-CcEncrypted { param([byte[]]$Plain, [SecureString]$Sec); Protect-PortableData $Plain $Sec 'PORTCC02' }
function ConvertFrom-CcEncrypted { param([byte[]]$Blob, [SecureString]$Sec); Unprotect-PortableData $Blob $Sec 'PORTCC02' }

# Read the password from -Password or the environment now, so the
# variables are gone before Claude Code starts.
$envPassword = Pop-PortableEnvPassword -Names @('CLAUDE_PASSWORD')
if ($null -eq $Password) { $Password = $envPassword }
Set-PortableChildEnvironment -HomeDirectory $DataDir

# Redirect all Claude Code state to the portable folder and stop it
# from updating / relocating itself.
$env:CLAUDE_CONFIG_DIR    = $configDir
$env:DISABLE_AUTOUPDATER  = '1'
$env:CLAUDE_NO_UPDATE_NOTIFIER = '1'

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
  Write-Host '[claude] Espacios de trabajo (sesiones\):'
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
  Write-Host '  Enter en blanco = salir sin abrir Claude Code'
  Write-Host ''

  while ($true) {
    $sel = (Read-Host -Prompt 'Seleccion').Trim()
    if ([string]::IsNullOrWhiteSpace($sel)) {
      return $null
    }
    $parsed = 0
    if ([int]::TryParse($sel, [ref]$parsed)) {
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

# Encrypt the plain .credentials.json and wipe it. On the first start
# there is no password yet: it is asked here, after /login has created
# the credentials. If encryption fails the plain file is kept (and
# encrypted on the next start) rather than lost. Safe to call multiple
# times; used from a finally block.
function Protect-Auth {
  if (-not (Test-Path -LiteralPath $auth)) { return $true }
  try {
    if ($null -eq $script:sessionPass) {
      Write-Host '[claude] Guardando las credenciales en el portable.'
      $script:sessionPass = Get-PortablePassword -Tool 'claude' -Provided $Password -ForNewCredentials
    }
    $enc = ConvertTo-CcEncrypted -Plain ([IO.File]::ReadAllBytes($auth)) -Sec $script:sessionPass
    Write-PortablePrivateBytes $authEnc $enc
    Remove-Item -LiteralPath $auth -Force
    return $true
  } catch {
    Write-Warning "[claude] No se pudieron cifrar las credenciales: $($_.Exception.Message)"
    Write-Warning "[claude] Siguen en claro en $auth; se cifraran en el proximo arranque."
    return $false
  }
}

$sessionPass = $null

# --- credentials left in the clear by an interrupted first save -------
if ((Test-Path -LiteralPath $auth) -and -not (Test-Path -LiteralPath $authEnc)) {
  Write-Host '[claude] Hay credenciales sin cifrar de una sesion anterior.'
  $null = Protect-Auth
  if (Test-Path -LiteralPath $auth) { exit 1 }
  if ($EncryptOnly) { Write-Host '[claude] Credenciales cifradas en .credentials.json.enc. No se arranca Claude Code.'; exit 0 }
}


# --- decrypt for this session -------------------------------------------
if (Test-Path -LiteralPath $authEnc) {
  try {
    if ($null -eq $sessionPass) { $sessionPass = Get-PortablePassword -Tool 'claude' -Provided $Password }
    $plain = ConvertFrom-CcEncrypted -Blob ([IO.File]::ReadAllBytes($authEnc)) -Sec $sessionPass
  } catch {
    [Console]::Error.WriteLine("[claude] No se pudieron descifrar las credenciales: $($_.Exception.Message)")
    [Console]::Error.WriteLine('[claude] Contrasena incorrecta o archivo corrupto. Abortando.')
    exit 2
  }
  Register-PortablePassword $sessionPass
  if (Test-Path -LiteralPath $auth) {
    # Left by a session that ended abruptly: newer than the encrypted copy
    # (for example a refreshed token). Keep it; it is encrypted on exit.
    Write-Host '[claude] Se conservan credenciales mas recientes de una sesion anterior.'
  } else {
    Write-PortablePrivateBytes $auth $plain
  }
  Set-PortableFileAcl -Path $auth
} elseif ($CmdArgs.Length -eq 0) {
  Write-Host '[claude] Este portable aun no tiene credenciales: inicia sesion con /login.'
  Write-Host '[claude] Al salir se te pedira la contrasena del portable para guardarlas cifradas.'
}

if ($EncryptOnly) {
  $null = Protect-Auth
  if (Test-Path -LiteralPath $auth) { exit 3 }
  exit 0
}

$code = 0
try {
  # --- select workspace & run Claude Code --------------------------
  $sessionDir   = $null
  $sesionesRoot = Join-Path $root 'sesiones'

  if (-not [string]::IsNullOrEmpty($Workspace)) {
    if ($Workspace -match '[\\/:*?"<>|]' -or [string]::IsNullOrWhiteSpace($Workspace) -or $Workspace -in @('.', '..')) {
      Write-Error "[claude] Nombre de workspace invalido: $Workspace"
      exit 1
    }
    $sessionDir = Join-Path $sesionesRoot $Workspace
    if (-not (Test-Path -LiteralPath $sessionDir)) {
      New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
      Write-Host "[claude] Carpeta creada: sesiones\$Workspace"
    }
    Write-Host "[claude] Abriendo sesion en: $Workspace"
    Write-Host ''
  } elseif ($CmdArgs.Length -eq 0) {
    $sessionDir = Select-Workspace -SesionesRoot $sesionesRoot
    if ($null -eq $sessionDir) {
      Write-Host '[claude] Cancelado.'
      exit 0
    }
    Write-Host "[claude] Abriendo sesion en: $(Split-Path $sessionDir -Leaf)"
    Write-Host ''
  }

  if ($null -ne $sessionDir) {
    Push-Location $sessionDir
    try { & $bin @CmdArgs } finally { Pop-Location }
  } else {
    Push-Location $root
    try { & $bin @CmdArgs } finally { Pop-Location }
  }
  if ($null -ne $LASTEXITCODE) { $code = $LASTEXITCODE } else { $code = 0 }
} finally {
  if ((Protect-Auth) -eq $false) { exit 3 }
}

exit $code

} finally { $portableSessionLock.Dispose() }
