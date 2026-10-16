# ============================================================
#  Instala o actualiza los asistentes portables en un pendrive (o en
#  cualquier otra carpeta) DESCARGANDOLOS DE INTERNET, y verifica que
#  todo esta bien.
#
#  Cada asistente se descarga de su fuente oficial (ver
#  portatil-programa.psd1) y se comprueba contra el hash publicado antes
#  de instalarlo. Solo los scripts (lanzadores y los de la raiz) se
#  copian desde la carpeta de este script.
#
#  Sin argumentos es un asistente: muestra los pendrives conectados,
#  pregunta donde instalar, consulta las ultimas versiones, muestra que
#  va a instalar o actualizar y pide confirmacion. Nunca toca sesiones,
#  credenciales ni la contrasena del destino.
#
#  Despues verifica:
#    - que cada archivo instalado coincide con el descargado (SHA-256,
#      inventario guardado en versiones.json)
#    - que no sobran archivos en las carpetas de programa
#    - que los scripts coinciden con los de origen y no tienen errores
#    - que el cifrado del destino funciona (cifrar y descifrar de prueba)
#    - que los cuatro ejecutables arrancan y son la version instalada
#    - el estado de las credenciales de cada asistente
#
#  Uso:
#    instalar.cmd                          asistente interactivo
#    instalar.cmd E:\portatil              instala/actualiza ahi (pregunta antes)
#    instalar.cmd E:\portatil -Si          sin confirmacion
#    instalar.cmd E:\portatil -Forzar      descarga todo aunque este al dia
#    instalar.cmd E:\portatil -SoloVerificar   sin internet ni cambios
#
#  Opciones:
#    -Destino <dir>    carpeta de instalacion (puede ser la de este script:
#                      entonces se actualiza a si misma)
#    -Si               no pedir confirmacion
#    -Forzar           volver a descargar aunque la version sea la misma
#    -SoloVerificar    no descarga ni copia nada; solo verifica el destino
# ============================================================

param(
  [Parameter(Position = 0)][string]$Destino = '',
  [switch]$Si,
  [switch]$Forzar,
  [switch]$SoloVerificar
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$Origen = $PSScriptRoot.TrimEnd('\')
. (Join-Path $Origen 'portable-crypto.ps1')
$manifestPath = Join-Path $Origen 'portatil-programa.psd1'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  [Console]::Error.WriteLine("[instalar] Falta portatil-programa.psd1 junto a este script.")
  exit 1
}
$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
$tools = @($manifest.Tools.Keys | Sort-Object)

# ------------------------------------------------------------------
#  Helpers
# ------------------------------------------------------------------
function Format-Size {
  param([double]$Bytes)
  if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
  if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
  return '{0:N0} KB' -f ($Bytes / 1KB)
}

function Test-Portatil {
  param([string]$Path)
  return (Test-Path -LiteralPath (Join-Path $Path 'portable-crypto.ps1') -PathType Leaf)
}

function Read-YesNo {
  param([string]$Prompt, [bool]$Default = $true)
  $suffix = if ($Default) { '[S/n]' } else { '[s/N]' }
  while ($true) {
    $answer = Read-Host -Prompt "$Prompt $suffix"
    if ($null -eq $answer) { return $Default }
    $answer = $answer.Trim().ToLower()
    if ($answer -eq '') { return $Default }
    if ($answer -in 's', 'si', 'y', 'yes') { return $true }
    if ($answer -in 'n', 'no') { return $false }
  }
}

function Get-FileSha256 {
  param([string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

# Script files, relative to the portatil root.
function Get-ScriptFiles {
  $list = [System.Collections.Generic.List[string]]::new()
  foreach ($f in $manifest.RootFiles) { $list.Add($f) }
  foreach ($tool in $tools) { foreach ($f in $manifest.Tools[$tool].Files) { $list.Add((Join-Path $tool $f)) } }
  return $list
}

# Program files of one assistant under $Base, relative to $Base.
function Get-ToolProgramFiles {
  param([string]$Base, [string]$Tool)
  $list = [System.Collections.Generic.List[string]]::new()
  $spec = $manifest.Tools[$Tool]
  foreach ($f in $spec.PackageFiles) {
    $rel = Join-Path $Tool $f
    if (Test-Path -LiteralPath (Join-Path $Base $rel) -PathType Leaf) { $list.Add($rel) }
  }
  foreach ($d in $spec.Dirs) {
    $dir = Join-Path $Base (Join-Path $Tool $d)
    if (Test-Path -LiteralPath $dir) {
      Get-ChildItem -LiteralPath $dir -Recurse -Force -File | ForEach-Object { $list.Add($_.FullName.Substring($Base.Length + 1)) }
    }
  }
  return $list
}

function Read-Inventory {
  param([string]$Path)
  $file = Join-Path $Path 'versiones.json'
  $inv = @{}
  if (-not (Test-Path -LiteralPath $file)) { return $inv }
  try {
    $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    foreach ($p in $json.PSObject.Properties) {
      $files = @{}
      if ($p.Value.files) { foreach ($f in $p.Value.files.PSObject.Properties) { $files[$f.Name] = [string]$f.Value } }
      $inv[$p.Name] = @{ version = [string]$p.Value.version; source = [string]$p.Value.source; installed = [string]$p.Value.installed; files = $files }
    }
  } catch { }
  return $inv
}

function Save-Inventory {
  param([string]$Path, [hashtable]$Inventory)
  $ordered = [ordered]@{}
  foreach ($k in ($Inventory.Keys | Sort-Object)) {
    $e = $Inventory[$k]
    $files = [ordered]@{}
    foreach ($f in ($e.files.Keys | Sort-Object)) { $files[$f] = $e.files[$f] }
    $ordered[$k] = [ordered]@{ version = $e.version; source = $e.source; installed = $e.installed; files = $files }
  }
  $json = $ordered | ConvertTo-Json -Depth 6
  [IO.File]::WriteAllText((Join-Path $Path 'versiones.json'), $json, (New-Object Text.UTF8Encoding($false)))
}

# Latest official release of an assistant: version, URL, expected hash.
function Get-LatestRelease {
  param([string]$Tool)
  $src = $manifest.Tools[$Tool].Source
  switch ($src.Type) {
    'claude' {
      $version = ([string](Invoke-RestMethod -Uri "$($src.BaseUrl)/$($src.Channel)" -UseBasicParsing)).Trim()
      if ($version -notmatch '^\d+\.\d+\.\d+') { throw "respuesta inesperada del servidor de versiones: '$version'" }
      $m = Invoke-RestMethod -Uri "$($src.BaseUrl)/$version/manifest.json" -UseBasicParsing
      $p = $m.platforms.($src.Platform)
      if (-not $p -or -not $p.checksum) { throw "el manifiesto de $version no incluye $($src.Platform)" }
      return @{ Version = $version; Url = "$($src.BaseUrl)/$version/$($src.Platform)/$($p.binary)"; Hash = ([string]$p.checksum).ToLower(); Algorithm = 'SHA256'; Size = [long]$p.size; FileName = [string]$p.binary }
    }
    'github' {
      $headers = @{ 'User-Agent' = 'portatil-instalar'; 'Accept' = 'application/vnd.github+json' }
      $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$($src.Repo)/releases/latest" -Headers $headers -UseBasicParsing
      $asset = @($r.assets | Where-Object { $_.name -eq $src.Asset }) | Select-Object -First 1
      if (-not $asset) { throw "la ultima version de $($src.Repo) no incluye $($src.Asset)" }
      $digest = [string]$asset.digest
      if ($digest -notmatch '^sha256:[0-9a-fA-F]{64}$') { throw "GitHub no publica el hash de $($src.Asset); no se instala sin verificar" }
      $version = ([string]$r.tag_name)
      if ($src.TagPrefix -and $version.StartsWith($src.TagPrefix)) { $version = $version.Substring($src.TagPrefix.Length) }
      return @{ Version = $version; Url = [string]$asset.browser_download_url; Hash = $digest.Substring(7).ToLower(); Algorithm = 'SHA256'; Size = [long]$asset.size; FileName = [string]$asset.name }
    }
    'agy' {
      $m = Invoke-RestMethod -Uri $src.Manifest -UseBasicParsing
      if (-not $m.version -or -not $m.url -or -not $m.sha512) { throw 'manifiesto de Antigravity incompleto' }
      return @{ Version = [string]$m.version; Url = [string]$m.url; Hash = ([string]$m.sha512).ToLower(); Algorithm = 'SHA512'; Size = [long]0; FileName = 'agy.exe' }
    }
    default { throw "tipo de fuente desconocido: $($src.Type)" }
  }
}

function Invoke-Download {
  param([string]$Url, [string]$OutFile)
  $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
  $originalEnvironment = @{}
  foreach ($entry in (Get-ChildItem Env:)) { $originalEnvironment[$entry.Name] = $entry.Value }
  try {
    Set-PortableChildEnvironment (Join-Path (Split-Path -Parent $OutFile) '.download-profile')
    if (Test-Path -LiteralPath $curl) {
      & $curl -q -L --fail --retry 3 --retry-delay 2 --progress-bar -o $OutFile $Url
      if ($LASTEXITCODE -ne 0) { throw "la descarga fallo (curl codigo $LASTEXITCODE)" }
    } else {
      Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    }
  } finally {
    foreach ($entry in @(Get-ChildItem Env:)) { Remove-Item -LiteralPath ("Env:" + $entry.Name) }
    foreach ($name in $originalEnvironment.Keys) { Set-Item -LiteralPath ("Env:" + $name) -Value $originalEnvironment[$name] }
  }
}

# /FFT: FAT/exFAT pendrives store times with 2-second precision.
function Invoke-Mirror {
  param([string]$From, [string]$To, [string[]]$Files = @())
  $rcArgs = @($From, $To) + $Files + @('/R:2', '/W:2', '/FFT', '/XJ', '/NP', '/NJH', '/NJS', '/NDL', '/NFL')
  if ($Files.Count -eq 0) { $rcArgs += '/MIR' }
  & robocopy.exe @rcArgs | Out-Null
  # robocopy: 0-7 = success (bit flags), 8+ = failure.
  if ($LASTEXITCODE -ge 8) { throw "robocopy termino con codigo $LASTEXITCODE copiando a $To" }
}

# ------------------------------------------------------------------
#  1. Destination
# ------------------------------------------------------------------
Write-Host ''
Write-Host '=== Instalar / actualizar los asistentes portables (desde internet) ===' -ForegroundColor Cyan
Write-Host ''

if ([string]::IsNullOrWhiteSpace($Destino)) {
  $drives = @(Get-Volume -ErrorAction SilentlyContinue |
    Where-Object { $_.DriveType -eq 'Removable' -and $_.DriveLetter } |
    Sort-Object DriveLetter)

  $choices = @()
  if ($drives.Count -eq 0) {
    Write-Host 'No se ha detectado ningun pendrive conectado.'
  } else {
    Write-Host 'Pendrives conectados:'
    foreach ($v in $drives) {
      $root = "$($v.DriveLetter):\"
      $existing = Join-Path $root 'portatil\windows'
      $note = if (Test-Portatil $existing) { "  [ya tiene portatil en $existing]" } else { '' }
      $label = if ($v.FileSystemLabel) { $v.FileSystemLabel } else { 'sin nombre' }
      $choices += $root
      Write-Host ('  {0}) {1}  {2}  {3}  {4} libres de {5}{6}' -f $choices.Count, $root, $label, $v.FileSystem,
        (Format-Size $v.SizeRemaining), (Format-Size $v.Size), $note)
    }
  }
  $otherIdx = $choices.Count + 1
  Write-Host ('  {0}) Escribir otra ruta' -f $otherIdx)
  Write-Host ''
  Write-Host '  Enter en blanco = salir'

  $base = $null
  while ($null -eq $base) {
    $sel = Read-Host -Prompt 'Seleccion'
    if ($null -eq $sel -or $sel.Trim() -eq '') { Write-Host '[instalar] Cancelado.'; exit 0 }
    $sel = $sel.Trim()
    $n = 0
    if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $choices.Count) {
      $base = $choices[$n - 1]
    } elseif ($n -eq $otherIdx) {
      $typed = (Read-Host -Prompt 'Ruta de la carpeta de instalacion').Trim().Trim('"')
      if ($typed) { $Destino = $typed; $base = '' }
    } else {
      Write-Host '  Opcion no valida.'
    }
  }
  if ($base) {
    $suggested = Join-Path $base 'portatil\windows'
    $typed = (Read-Host -Prompt "Carpeta de instalacion [$suggested]").Trim().Trim('"')
    $Destino = if ($typed) { $typed } else { $suggested }
  }
}

$Destino = [IO.Path]::GetFullPath($Destino).TrimEnd('\')
if ($Destino.Length -le 3) {
  # A bare drive root would mix the portable with everything else on it.
  $Destino = Join-Path $Destino 'portatil\windows'
  Write-Host "[instalar] Se usara la carpeta $Destino"
}
$selfUpdate = ($Destino -ieq $Origen)
Assert-PortablePath -Root $Destino -Path $Destino
if (Test-Path -LiteralPath $Destino) { Assert-PortableTree -Root $Destino }
$isUpdate = Test-Portatil $Destino

if ($SoloVerificar -and -not $isUpdate) {
  [Console]::Error.WriteLine("[instalar] $Destino no contiene una instalacion portatil que verificar.")
  exit 1
}
if (-not $isUpdate -and -not $SoloVerificar -and (Test-Path -LiteralPath $Destino)) {
  $other = @(Get-ChildItem -LiteralPath $Destino -Force -ErrorAction SilentlyContinue)
  if ($other.Count -gt 0) {
    Write-Host ''
    Write-Host "[instalar] AVISO: $Destino ya existe, no esta vacia y no es una instalacion portatil." -ForegroundColor Yellow
    Write-Host '[instalar] Se anadiran los archivos del portable sin borrar lo que hay.'
    if (-not $Si -and -not (Read-YesNo 'Continuar de todos modos?' $false)) { Write-Host '[instalar] Cancelado.'; exit 0 }
  }
}

$volume = $null
$qualifier = ''
if ($Destino -match '^([A-Za-z]):') {
  $qualifier = "$($Matches[1]):"
  $volume = Get-Volume -DriveLetter $Matches[1] -ErrorAction SilentlyContinue
}

$inventory = Read-Inventory $Destino
$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
function Report {
  param([string]$Status, [string]$Text)
  $color = switch ($Status) { 'OK' { 'Green' } 'AVISO' { 'Yellow' } default { 'Red' } }
  Write-Host ('  [{0,-5}] {1}' -f $Status, $Text) -ForegroundColor $color
  if ($Status -eq 'FALLO') { $failures.Add($Text) }
  if ($Status -eq 'AVISO') { $warnings.Add($Text) }
}

# ------------------------------------------------------------------
#  2. Plan: latest versions, what to do, space, confirmation
# ------------------------------------------------------------------
$plan = [ordered]@{}
if (-not $SoloVerificar) {
  # A running assistant keeps its exe locked and has plain credentials on disk.
  $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and $_.Path.StartsWith($Destino + '\', [StringComparison]::OrdinalIgnoreCase)
  })
  if ($running.Count -gt 0) {
    Write-Host '[instalar] Hay asistentes del destino en ejecucion; cierralos antes de continuar:'
    $running | ForEach-Object { Write-Host "  $($_.ProcessName) ($($_.Id))  $($_.Path)" }
    exit 1
  }

  Write-Host 'Consultando las ultimas versiones oficiales...'
  foreach ($tool in $tools) {
    $installed = $null
    if ($inventory.ContainsKey($tool)) { $installed = $inventory[$tool].version }
    $exePresent = Test-Path -LiteralPath (Join-Path $Destino (Join-Path $tool $manifest.Tools[$tool].Exe))
    try {
      $rel = Get-LatestRelease $tool
    } catch {
      $plan[$tool] = @{ Action = 'error'; Error = $_.Exception.Message; Installed = $installed }
      continue
    }
    $action = 'instalar'
    if ($installed -and $exePresent) {
      if ($installed -ne $rel.Version) { $action = 'actualizar' }
      else {
        # Same version: repair only if an inventoried file is missing or changed size.
        $action = 'al dia'
        foreach ($f in $inventory[$tool].files.Keys) {
          if (-not (Test-Path -LiteralPath (Join-Path $Destino $f))) { $action = 'reparar'; break }
        }
        if ($Forzar) { $action = 'reinstalar' }
      }
    } elseif ($exePresent) {
      $action = 'actualizar'   # installed without inventory (older installer)
    }
    $plan[$tool] = @{ Action = $action; Release = $rel; Installed = $installed }
  }

  Write-Host ''
  Write-Host ('  {0,-12} {1,-14} {2,-14} {3}' -f 'Asistente', 'Instalada', 'Disponible', 'Accion')
  foreach ($tool in $tools) {
    $p = $plan[$tool]
    $inst = if ($p.Installed) { $p.Installed } elseif (Test-Path -LiteralPath (Join-Path $Destino (Join-Path $tool $manifest.Tools[$tool].Exe))) { 'desconocida' } else { '-' }
    if ($p.Action -eq 'error') {
      Write-Host ('  {0,-12} {1,-14} {2,-14} {3}' -f $tool, $inst, '?', "ERROR: $($p.Error)") -ForegroundColor Red
    } else {
      Write-Host ('  {0,-12} {1,-14} {2,-14} {3}' -f $tool, $inst, $p.Release.Version, $p.Action)
    }
  }

  $todo = @($tools | Where-Object { $plan[$_].Action -in 'instalar', 'actualizar', 'reparar', 'reinstalar' })
  $scriptsChanged = $false
  if (-not $selfUpdate) {
    foreach ($rel in (Get-ScriptFiles)) {
      $src = Join-Path $Origen $rel; $dst = Join-Path $Destino $rel
      if (-not (Test-Path -LiteralPath $dst) -or (Get-FileSha256 $src) -ne (Get-FileSha256 $dst)) { $scriptsChanged = $true; break }
    }
  }

  # Keep staging and replacement copies on the installation volume.
  # Archives grow roughly 3x when unpacked; Antigravity publishes no size.
  $needDest = [long]200MB
  $needTemp = [long]0
  foreach ($tool in $todo) {
    $r = $plan[$tool].Release
    $unpacked = if ($manifest.Tools[$tool].Source.Extract -eq 'none') { $r.Size } else { $r.Size * 3 }
    if ($unpacked -le 0) { $unpacked = 250MB }
    $needDest += $unpacked
    $needTemp += $unpacked + $r.Size
  }
  $needDest += $needTemp
  if ($todo.Count -gt 0 -and $null -ne $volume -and $volume.SizeRemaining -lt $needDest) {
    [Console]::Error.WriteLine("[instalar] Espacio insuficiente en $qualifier : hacen falta unos $(Format-Size $needDest) y hay $(Format-Size $volume.SizeRemaining) libres.")
    exit 1
  }
  $tempRoot = Join-Path $Destino '.portable-tmp'
  if ($todo.Count -gt 0 -and $tempRoot -match '^([A-Za-z]):') {
    $tv = Get-Volume -DriveLetter $Matches[1] -ErrorAction SilentlyContinue
    if ($null -ne $tv -and $tv.SizeRemaining -lt ($needTemp + 200MB)) {
      [Console]::Error.WriteLine("[instalar] Espacio insuficiente en la carpeta temporal ($tempRoot): hacen falta unos $(Format-Size ($needTemp + 200MB)).")
      exit 1
    }
  }

  Write-Host ''
  if ($todo.Count -eq 0 -and -not $scriptsChanged -and $isUpdate) {
    Write-Host 'Todo esta al dia; solo se verificara la instalacion.' -ForegroundColor Green
  } else {
    if ($selfUpdate) { Write-Host "Se va a actualizar ESTA carpeta ($Destino) desde internet." -ForegroundColor Cyan }
    elseif ($isUpdate) { Write-Host "Se va a ACTUALIZAR el portable de $Destino" -ForegroundColor Cyan }
    else { Write-Host "Se va a INSTALAR el portable en $Destino" -ForegroundColor Cyan }
    if ($isUpdate) { Write-Host '  Se conservan sus sesiones, credenciales y contrasena.' }
    else { Write-Host '  Instalacion limpia: cada asistente pedira iniciar sesion la primera vez.' }
    $dl = [long]0; foreach ($tool in $todo) { $dl += $plan[$tool].Release.Size }
    if ($todo.Count -gt 0) { Write-Host ("  Descargas: {0} ({1}{2})" -f ($todo -join ', '), (Format-Size $dl), $(if ($todo -contains 'antigravity') { ' + Antigravity' } else { '' })) }
    if ($scriptsChanged) { Write-Host "  Scripts: se copian desde $Origen" }
    if ($null -ne $volume) { Write-Host ("  Unidad {0} {1}: {2} libres" -f $qualifier, $volume.FileSystem, (Format-Size $volume.SizeRemaining)) }
    Write-Host ''
    if (-not $Si -and -not (Read-YesNo 'Continuar?' $true)) { Write-Host '[instalar] Cancelado.'; exit 0 }
  }

  # ------------------------------------------------------------------
  #  3. Install
  # ------------------------------------------------------------------
  New-Item -ItemType Directory -Path $Destino -Force | Out-Null

  if (-not $selfUpdate) {
    Write-Host ''
    Write-Host 'Copiando scripts...'
    $rootFiles = @($manifest.RootFiles | Where-Object { Test-Path -LiteralPath (Join-Path $Origen $_) })
    Invoke-Mirror -From $Origen -To $Destino -Files $rootFiles
    foreach ($tool in $tools) {
      $files = @($manifest.Tools[$tool].Files | Where-Object { Test-Path -LiteralPath (Join-Path (Join-Path $Origen $tool) $_) })
      if ($files.Count -gt 0) { Invoke-Mirror -From (Join-Path $Origen $tool) -To (Join-Path $Destino $tool) -Files $files }
    }
    foreach ($old in @($manifest.ObsoleteFiles)) {
      $oldPath = Join-Path $Destino $old
      if ($old -and (Test-Path -LiteralPath $oldPath -PathType Leaf)) {
        Remove-Item -LiteralPath $oldPath -Force
        Write-Host "  Eliminado script obsoleto: $old"
      }
    }
  }

  New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
  $staging = Join-Path $tempRoot ('portatil-descargas-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $staging -Force | Out-Null
  try {
    foreach ($tool in $todo) {
      $spec = $manifest.Tools[$tool]
      $r = $plan[$tool].Release
      Write-Host ''
      Write-Host ("Descargando {0} {1}{2}..." -f $tool, $r.Version, $(if ($r.Size -gt 0) { " ($(Format-Size $r.Size))" } else { '' }))
      try {
        $download = Join-Path $staging ("$tool-" + $r.FileName)
        Invoke-Download -Url $r.Url -OutFile $download
        $hash = (Get-FileHash -LiteralPath $download -Algorithm $r.Algorithm).Hash.ToLower()
        if ($hash -ne $r.Hash) { throw "el $($r.Algorithm) de la descarga no coincide con el publicado; posible descarga corrupta o manipulada" }
        Write-Host "  $($r.Algorithm) verificado."

        # Unpack into a tree that mirrors the assistant folder.
        $tree = Join-Path $staging $tool
        New-Item -ItemType Directory -Path $tree -Force | Out-Null
        switch ($spec.Source.Extract) {
          'none'  {
            $target = Join-Path $tree $spec.Exe
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Move-Item -LiteralPath $download -Destination $target
          }
          'zip'   {
            $into = Join-Path $tree $spec.Source.Into
            New-Item -ItemType Directory -Path $into -Force | Out-Null
            Expand-Archive -LiteralPath $download -DestinationPath $into -Force
          }
          'targz' {
            $into = Join-Path $tree $spec.Source.Into
            New-Item -ItemType Directory -Path $into -Force | Out-Null
            & (Join-Path $env:SystemRoot 'System32\tar.exe') -xzf $download -C $into
            if ($LASTEXITCODE -ne 0) { throw "no se pudo descomprimir (tar codigo $LASTEXITCODE)" }
          }
        }

        # The download must provide everything the launcher needs.
        $missing = @()
        foreach ($d in $spec.Dirs) { if (-not (Test-Path -LiteralPath (Join-Path $tree $d))) { $missing += $d } }
        foreach ($f in $spec.PackageFiles) { if (-not (Test-Path -LiteralPath (Join-Path $tree $f))) { $missing += $f } }
        if (-not (Test-Path -LiteralPath (Join-Path $tree $spec.Exe))) { $missing += $spec.Exe }
        if ($missing.Count -gt 0) { throw "el paquete descargado no contiene: $($missing -join ', '); no se instala" }

        # Inventory from the verified download, then place it.
        $files = @{}
        foreach ($rel in (Get-ToolProgramFiles -Base $staging -Tool $tool)) { $files[$rel] = Get-FileSha256 (Join-Path $staging $rel) }
        $destTool = Join-Path $Destino $tool
        foreach ($d in $spec.Dirs) { Invoke-Mirror -From (Join-Path $tree $d) -To (Join-Path $destTool $d) }
        if ($spec.PackageFiles.Count -gt 0) { Invoke-Mirror -From $tree -To $destTool -Files $spec.PackageFiles }
        Get-ChildItem -LiteralPath $destTool -Recurse -Force -File -Include *.exe, *.dll -ErrorAction SilentlyContinue |
          ForEach-Object { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }

        $inventory[$tool] = @{ version = $r.Version; source = $r.Url; installed = (Get-Date).ToString('yyyy-MM-dd HH:mm'); files = $files }
        Save-Inventory -Path $Destino -Inventory $inventory
        Write-Host "  Instalado en $destTool"
      } catch {
        Report 'FALLO' "${tool}: $($_.Exception.Message) (se conserva la version anterior si la habia)"
      } finally {
        Remove-Item -LiteralPath (Join-Path $staging $tool) -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $staging -File -Filter "$tool-*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
      }
    }
  } finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
  }
  foreach ($tool in $tools) {
    if ($plan[$tool].Action -eq 'error') { Report 'FALLO' "${tool}: no se pudo consultar la ultima version: $($plan[$tool].Error)" }
  }
}

# ------------------------------------------------------------------
#  4. Verification
# ------------------------------------------------------------------
Write-Host ''
Write-Host "=== Verificando $Destino ===" -ForegroundColor Cyan
$inventory = Read-Inventory $Destino

# 4a. Program files match the inventory of the verified downloads.
Write-Host '  Comprobando archivos (SHA-256), puede tardar un poco...'
foreach ($tool in $tools) {
  if (-not $inventory.ContainsKey($tool)) {
    if (Test-Path -LiteralPath (Join-Path $Destino (Join-Path $tool $manifest.Tools[$tool].Exe))) {
      Report 'AVISO' ("{0,-12} instalado sin inventario (version antigua del instalador); ejecuta instalar.cmd para actualizarlo" -f $tool)
    } else {
      Report 'FALLO' ("{0,-12} no esta instalado" -f $tool)
    }
    continue
  }
  $entry = $inventory[$tool]
  $bad = @()
  foreach ($rel in $entry.files.Keys) {
    $path = Join-Path $Destino $rel
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $bad += "falta $rel"; continue }
    if ((Get-FileSha256 $path) -ne $entry.files[$rel]) { $bad += "alterado $rel" }
  }
  $known = @{}; foreach ($k in $entry.files.Keys) { $known[$k.ToLower()] = $true }
  $extra = @(Get-ToolProgramFiles -Base $Destino -Tool $tool | Where-Object { -not $known.ContainsKey($_.ToLower()) })
  if ($bad.Count -eq 0) {
    Report 'OK' ("{0,-12} {1}: {2} archivos identicos a la descarga verificada" -f $tool, $entry.version, $entry.files.Count)
  } else {
    foreach ($b in $bad) { Report 'FALLO' ("{0,-12} {1}" -f $tool, $b) }
  }
  foreach ($e in $extra) { Report 'AVISO' ("{0,-12} sobra (no es de la version instalada): {1}" -f $tool, $e) }
}

# 4b. Scripts: present, equal to the source copy, and parse.
$scriptFiles = Get-ScriptFiles
$scriptBad = @()
foreach ($rel in $scriptFiles) {
  $dst = Join-Path $Destino $rel
  if (-not (Test-Path -LiteralPath $dst)) { $scriptBad += "falta $rel"; continue }
  if (-not $selfUpdate -and (Test-Path -LiteralPath (Join-Path $Origen $rel)) -and
      (Get-FileSha256 (Join-Path $Origen $rel)) -ne (Get-FileSha256 $dst)) { $scriptBad += "distinto del origen: $rel" }
  if ($rel -like '*.ps1') {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($dst, [ref]$null, [ref]$errors)
    if ($errors) { $scriptBad += "error de sintaxis en ${rel}: $($errors[0].Message)" }
  }
}
if ($scriptBad.Count -eq 0) { Report 'OK' "$($scriptFiles.Count) scripts correctos" }
elseif ($SoloVerificar) { foreach ($b in $scriptBad) { if ($b -like 'distinto*') { Report 'AVISO' "Script $b" } else { Report 'FALLO' "Script $b" } } }
else { foreach ($b in $scriptBad) { Report 'FALLO' "Script $b" } }

# 4c. Encryption module of the destination works (in-memory round trip).
$cryptoOk = $false
try {
  $cryptoOk = & {
    . (Join-Path $Destino 'portable-crypto.ps1')
    $pw = ConvertTo-SecureString ([guid]::NewGuid().ToString()) -AsPlainText -Force
    $sample = [Text.Encoding]::UTF8.GetBytes('verificacion-portatil')
    $blob = Protect-PortableData $sample $pw 'PORTVF02'
    return ([Text.Encoding]::UTF8.GetString((Unprotect-PortableData $blob $pw 'PORTVF02')) -eq 'verificacion-portatil')
  }
} catch { $cryptoOk = $false }
if ($cryptoOk) { Report 'OK' 'Cifrado de credenciales operativo' } else { Report 'FALLO' 'El modulo de cifrado (portable-crypto.ps1) no funciona en el destino' }

# 4d. Executables start on this computer and report the installed version.
# State is redirected to a throwaway folder so nothing is written to the
# portable or to this computer's profile.
function Invoke-Version {
  param([string]$Exe, [hashtable]$Environment, [int]$TimeoutMs = 60000)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe
  $psi.Arguments = '--version'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.RedirectStandardInput = $true
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = $scratch
  . (Join-Path $Destino 'portable-crypto.ps1')
  $childEnvironment = Get-PortableChildEnvironment $scratch
  $psi.EnvironmentVariables.Clear()
  foreach ($k in $childEnvironment.Keys) { $psi.EnvironmentVariables[$k] = [string]$childEnvironment[$k] }
  foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[$k] = [string]$Environment[$k] }
  foreach ($name in @('TEMP', 'XDG_RUNTIME_DIR')) { New-Item -ItemType Directory -Path $childEnvironment[$name] -Force | Out-Null }
  $p = [System.Diagnostics.Process]::Start($psi)
  $p.StandardInput.Close()
  $stdout = $p.StandardOutput.ReadToEndAsync()
  $stderr = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($TimeoutMs)) {
    try { $p.Kill() } catch { }
    return @{ Code = -1; Text = 'no respondio en 60 s' }
  }
  $text = (($stdout.Result + "`n" + $stderr.Result) -split "`r?`n" | Where-Object { $_.Trim() } |
    Where-Object { $_ -notmatch '^WARNING:' } | Select-Object -First 1)
  return @{ Code = $p.ExitCode; Text = "$text".Trim() }
}

$temporaryRoot = Join-Path $Destino '.portable-tmp'
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
$scratch = Join-Path $temporaryRoot ('portatil-verificar-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
  $envByTool = @{
    antigravity = @{ USERPROFILE = $scratch; HOME = $scratch; APPDATA = $scratch; LOCALAPPDATA = $scratch; AGY_CLI_DISABLE_AUTO_UPDATE = '1' }
    claude      = @{ CLAUDE_CONFIG_DIR = $scratch; DISABLE_AUTOUPDATER = '1'; CLAUDE_NO_UPDATE_NOTIFIER = '1' }
    codex       = @{ CODEX_HOME = $scratch; PATH = (Join-Path $Destino 'codex\codex-path') + ';' + $env:PATH }
    oc          = @{ XDG_DATA_HOME = $scratch; XDG_CONFIG_HOME = $scratch; XDG_CACHE_HOME = $scratch; OPENCODE_DISABLE_AUTOUPDATE = '1' }
  }
  foreach ($tool in $tools) {
    $exe = Join-Path $Destino (Join-Path $tool $manifest.Tools[$tool].Exe)
    if (-not (Test-Path -LiteralPath $exe)) { continue }   # already reported above
    $envVars = @{}
    if ($envByTool.ContainsKey($tool)) { $envVars = $envByTool[$tool] }
    try {
      $r = Invoke-Version -Exe $exe -Environment $envVars
      if ($r.Code -ne 0) { Report 'FALLO' ("{0,-12} no arranca (codigo {1}): {2}" -f $tool, $r.Code, $r.Text); continue }
      $expected = if ($inventory.ContainsKey($tool)) { $inventory[$tool].version } else { $null }
      if ($expected -and $r.Text -notlike "*$expected*") { Report 'AVISO' ("{0,-12} arranca pero informa '{1}' en vez de {2}" -f $tool, $r.Text, $expected) }
      else { Report 'OK' ("{0,-12} arranca: {1}" -f $tool, $r.Text) }
    } catch {
      Report 'FALLO' ("{0,-12} no arranca: {1}" -f $tool, $_.Exception.Message)
    }
  }
} finally {
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

# 4e. Credentials state of each assistant.
$credPaths = @{
  antigravity = @{ Enc = 'antigravity\data\.gemini\auth.json.enc'; Plain = @('antigravity\data\.gemini\oauth_creds.json', 'antigravity\data\.gemini\google_accounts.json', 'antigravity\data\.gemini\auth.json') }
  claude      = @{ Enc = 'claude\data\claude\.credentials.json.enc'; Plain = @('claude\data\claude\.credentials.json') }
  codex       = @{ Enc = 'codex\data\codex\auth.json.enc'; Plain = @('codex\data\codex\auth.json', 'codex\data\codex\.credentials.json') }
  oc          = @{ Enc = 'oc\data\opencode\auth.json.enc'; Plain = @('oc\data\opencode\auth.json', 'oc\data\opencode\mcp-auth.json') }
}
$anyEnc = $false
foreach ($tool in $tools) {
  if (-not $credPaths.ContainsKey($tool)) { continue }
  $c = $credPaths[$tool]
  $plainLeft = @($c.Plain | Where-Object { Test-Path -LiteralPath (Join-Path $Destino $_) })
  if ($plainLeft.Count -gt 0) {
    Report 'AVISO' ("{0,-12} tiene credenciales SIN CIFRAR ({1}); arrancalo y cierralo normalmente para cifrarlas" -f $tool, ($plainLeft -join ', '))
  } elseif (Test-Path -LiteralPath (Join-Path $Destino $c.Enc)) {
    $anyEnc = $true
    Report 'OK' ("{0,-12} credenciales cifradas" -f $tool)
  } else {
    if ($tool -eq 'antigravity') { Write-Host ("  [INFO ] {0,-12} instalado, pero el inicio de sesion esta bloqueado (usaria el almacen de credenciales del PC); solo --version y --help" -f $tool) -ForegroundColor Cyan }
    else { Report 'OK' ("{0,-12} sin credenciales: pedira iniciar sesion la primera vez" -f $tool) }
  }
}
# Host credential stores are intentionally not inspected.
$passcheck = Join-Path $Destino 'portatil.passcheck'
if ($anyEnc -and -not (Test-Path -LiteralPath $passcheck)) {
  Report 'AVISO' 'Hay credenciales cifradas pero falta portatil.passcheck; se creara al abrir un asistente con la contrasena'
} elseif (Test-Path -LiteralPath $passcheck) {
  Report 'OK' 'Contrasena comun configurada (portatil.passcheck)'
}
if ($null -ne $volume -and $volume.FileSystem -in 'FAT32', 'exFAT', 'FAT') {
  Write-Host ("  [INFO ] Unidad {0}: los permisos de Windows no se aplican; las credenciales en claro solo existen mientras un asistente esta abierto." -f $volume.FileSystem)
}

# ------------------------------------------------------------------
#  5. Result
# ------------------------------------------------------------------
Write-Host ''
if ($failures.Count -eq 0) {
  $msg = if ($warnings.Count -gt 0) { "Todo correcto, con $($warnings.Count) aviso(s)." } else { 'Todo correcto.' }
  Write-Host "[instalar] $msg El portable de $Destino esta listo." -ForegroundColor Green
  Write-Host "[instalar] Para empezar: $Destino\claude\claude.cmd (o codex, oc)."
  Write-Host "[instalar] Para actualizarlo mas adelante: $Destino\actualizar.cmd"
  Write-Host '[instalar] Cierra siempre los asistentes antes de retirar el pendrive.'
  exit 0
}
Write-Host "[instalar] Hubo $($failures.Count) problema(s). Vuelve a ejecutar instalar.cmd (con -Forzar para descargar todo de nuevo)." -ForegroundColor Red
exit 2
