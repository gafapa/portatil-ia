# Antigravity OAuth cannot satisfy folder-only credential storage.
# The native CLI uses the host Credential Manager. Normal sessions fail
# closed until a separately configured portable API authentication mode
# is implemented. No host credential store is read or modified here.
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
    if ($i -ge $args.Count) { [Console]::Error.WriteLine("[antigravity] Falta el valor para: $token"); exit 1 }
    if ($optionName -in @('Password')) { $Password = ConvertTo-SecureString ([string]$args[$i]) -AsPlainText -Force }
    elseif ($optionName -eq 'DataDir') { $DataDir = [string]$args[$i] }
    else { $Workspace = [string]$args[$i] }
  } else {
    $argumentList.Add($token)
  }
}
$CmdArgs = [string[]]$argumentList.ToArray()
$root = $PSScriptRoot
. (Join-Path (Split-Path -Parent $root) 'portable-crypto.ps1')
Assert-PortableTree -Root $root
if ([string]::IsNullOrEmpty($DataDir)) { $DataDir = Join-Path $root 'data' }
Assert-PortablePath -Root $root -Path $DataDir
$allowed = @('--version', '-v', '-V', '--help', '-h', '/?', 'help', 'version')
$isInformational = $CmdArgs.Count -gt 0 -and -not $EncryptOnly -and [string]::IsNullOrEmpty($Workspace)
foreach ($argument in $CmdArgs) {
  if ($argument -notin $allowed) { $isInformational = $false }
}
if (-not $isInformational) {
  [Console]::Error.WriteLine('[antigravity] OAuth usa el almacen de credenciales del equipo. Este modo esta bloqueado: las credenciales deben permanecer solo en el portable.')
  exit 1
}
$bin = Join-Path $root 'bin/agy.exe'
if (-not (Test-Path -LiteralPath $bin -PathType Leaf)) {
  [Console]::Error.WriteLine('[antigravity] Falta el programa; ejecuta actualizar.cmd.')
  exit 1
}
$null = Pop-PortableEnvPassword -Names @('ANTIGRAVITY_PASSWORD')
Set-PortableChildEnvironment -HomeDirectory $DataDir
$env:AGY_CLI_DISABLE_AUTO_UPDATE = '1'
Push-Location $root
try { & $bin @CmdArgs; $code = $LASTEXITCODE } finally { Pop-Location }
exit $code
