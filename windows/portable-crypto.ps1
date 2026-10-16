# Password-based portable encryption compatible with Windows PowerShell 5.1.

# Construct child environments from an allowlist, never from provider names.
# This also excludes unknown API keys, tokens, proxies, and agent sockets.
function Get-PortableChildEnvironment {
  param([Parameter(Mandatory = $true)][string]$HomeDirectory)
  $allowed = @('PATH', 'PATHEXT', 'SYSTEMROOT', 'WINDIR', 'COMSPEC',
    'LANG', 'LANGUAGE', 'TZ',
    'LC_ALL', 'LC_CTYPE', 'LC_MESSAGES', 'LC_COLLATE', 'LC_NUMERIC',
    'LC_TIME', 'LC_MONETARY', 'LC_PAPER', 'LC_NAME', 'LC_ADDRESS',
    'LC_TELEPHONE', 'LC_MEASUREMENT', 'LC_IDENTIFICATION',
    'TERM', 'COLORTERM', 'TERM_PROGRAM', 'TERM_PROGRAM_VERSION',
    'DISPLAY', 'WAYLAND_DISPLAY')
  $childEnvironment = @{}
  foreach ($entry in (Get-ChildItem Env:)) {
    $name = $entry.Name.ToUpperInvariant()
    if ($name -in $allowed) {
      $childEnvironment[$entry.Name] = $entry.Value
    }
  }
  $configDirectory = Join-Path $HomeDirectory '.config'
  $temporaryDirectory = Join-Path $HomeDirectory 'tmp'
  foreach ($name in @('TEMP', 'TMP', 'TMPDIR', 'CLAUDE_CODE_TMPDIR')) { $childEnvironment[$name] = $temporaryDirectory }
  $childEnvironment['XDG_RUNTIME_DIR'] = Join-Path $HomeDirectory 'runtime'
  $childEnvironment['HOME'] = $HomeDirectory
  $childEnvironment['USERPROFILE'] = $HomeDirectory
  $childEnvironment['APPDATA'] = $configDirectory
  $childEnvironment['LOCALAPPDATA'] = Join-Path $HomeDirectory '.cache'
  $childEnvironment['XDG_CONFIG_HOME'] = $configDirectory
  $childEnvironment['XDG_DATA_HOME'] = Join-Path $HomeDirectory '.local/share'
  $childEnvironment['XDG_CACHE_HOME'] = Join-Path $HomeDirectory '.cache'
  $childEnvironment['XDG_STATE_HOME'] = Join-Path $HomeDirectory '.local/state'
  $childEnvironment['AWS_CONFIG_FILE'] = Join-Path $HomeDirectory '.aws/config'
  $childEnvironment['AWS_SHARED_CREDENTIALS_FILE'] = Join-Path $HomeDirectory '.aws/credentials'
  $childEnvironment['BOTO_CONFIG'] = Join-Path $HomeDirectory '.boto'
  $childEnvironment['BOTO_PATH'] = Join-Path $HomeDirectory '.boto'
  $childEnvironment['CLOUDSDK_CONFIG'] = Join-Path $configDirectory 'gcloud'
  $childEnvironment['AZURE_CONFIG_DIR'] = Join-Path $HomeDirectory '.azure'
  $childEnvironment['KUBECONFIG'] = Join-Path $HomeDirectory '.kube/config'
  $childEnvironment['GIT_CONFIG_GLOBAL'] = Join-Path $HomeDirectory '.gitconfig'
  $childEnvironment['GIT_CONFIG_NOSYSTEM'] = '1'
  $childEnvironment['AWS_EC2_METADATA_DISABLED'] = 'true'
  return $childEnvironment
}

function Set-PortableChildEnvironment {
  param([Parameter(Mandatory = $true)][string]$HomeDirectory)
  New-Item -ItemType Directory -Path $HomeDirectory -Force | Out-Null
  $childEnvironment = Get-PortableChildEnvironment $HomeDirectory
  foreach ($name in @('TEMP', 'XDG_RUNTIME_DIR')) {
    New-Item -ItemType Directory -Path $childEnvironment[$name] -Force | Out-Null
  }
  foreach ($entry in @(Get-ChildItem Env:)) {
    if (-not $childEnvironment.ContainsKey($entry.Name)) {
      Remove-Item -LiteralPath ("Env:" + $entry.Name) -ErrorAction Stop
    }
  }
  foreach ($name in $childEnvironment.Keys) {
    Set-Item -LiteralPath ("Env:" + $name) -Value $childEnvironment[$name]
  }
}

function Assert-PortablePath {
  param([string]$Root, [string]$Path)
  $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
  $target = [IO.Path]::GetFullPath($Path)
  if ($target -ine $base -and -not $target.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Path must remain inside the portable folder: $target"
  }
  $current = $target
  while ($current) {
    $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
    if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "Linked portable paths are not allowed: $current"
    }
    if ($current -ieq $base) { break }
    $current = Split-Path -Parent $current
  }
}

function Assert-PortableTree {
  param([string]$Root)
  Assert-PortablePath $Root $Root
  foreach ($item in (Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction Stop)) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked portable paths are not allowed: $($item.FullName)" }
  }
}

function Open-PortableSessionLock {
  param([string]$Root)
  $path = Join-Path $Root '.portable-session.lock'
  Assert-PortablePath -Root $Root -Path $path
  try { return (New-Object IO.FileStream($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)) }
  catch { throw 'Another session of this portable assistant is already running, or its lock cannot be opened.' }
}

function Write-PortablePrivateBytes {
  param([string]$Path, [byte[]]$Data)
  Assert-PortablePath -Root $PSScriptRoot -Path $Path
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  $temporary = Join-Path $parent ('.portable-save-' + [guid]::NewGuid().ToString('N'))
  try {
    $stream = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
      Set-PortableFileAcl -Path $temporary
      $stream.Write($Data, 0, $Data.Length)
      $stream.Flush($true)
    } finally { $stream.Dispose() }
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temporary, $Path) }
  } finally {
    if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
  }
}

function Get-PortablePasswordBytes {
  param([Security.SecureString]$Password)
  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
  try { return [Text.Encoding]::UTF8.GetBytes([Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Get-PortableKeyMaterial {
  param([byte[]]$PasswordBytes, [byte[]]$Salt)
  $deriver = New-Object Security.Cryptography.Rfc2898DeriveBytes($PasswordBytes, $Salt, 210000, [Security.Cryptography.HashAlgorithmName]::SHA256)
  try { return $deriver.GetBytes(64) } finally { $deriver.Dispose() }
}

function Protect-PortableData {
  param([byte[]]$Plaintext, [Security.SecureString]$Password, [string]$Magic)
  if ($Magic.Length -ne 8) { throw 'Portable encryption magic must contain exactly 8 ASCII characters.' }
  $passwordBytes = Get-PortablePasswordBytes $Password
  try {
    $salt = New-Object byte[] 16; $iv = New-Object byte[] 16
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($salt); $random.GetBytes($iv) } finally { $random.Dispose() }
    $keys = Get-PortableKeyMaterial $passwordBytes $salt
    try {
      $aes = [Security.Cryptography.Aes]::Create(); $aes.Key = [byte[]]$keys[0..31]; $aes.IV = $iv
      try { $encryptor = $aes.CreateEncryptor(); try { $ciphertext = $encryptor.TransformFinalBlock($Plaintext, 0, $Plaintext.Length) } finally { $encryptor.Dispose() } } finally { $aes.Dispose() }
      $authenticatedData = [Text.Encoding]::ASCII.GetBytes($Magic) + $salt + $iv + $ciphertext
      $hmac = New-Object Security.Cryptography.HMACSHA256(,([byte[]]$keys[32..63]))
      try { return $authenticatedData + $hmac.ComputeHash($authenticatedData) } finally { $hmac.Dispose() }
    } finally { [Array]::Clear($keys, 0, $keys.Length) }
  } finally { [Array]::Clear($passwordBytes, 0, $passwordBytes.Length) }
}

function Unprotect-PortableData {
  param([byte[]]$Blob, [Security.SecureString]$Password, [string]$Magic)
  if ($Blob.Length -lt 88 -or [Text.Encoding]::ASCII.GetString($Blob, 0, 8) -ne $Magic) { throw 'Unsupported portable credential format.' }
  $salt = [byte[]]$Blob[8..23]; $iv = [byte[]]$Blob[24..39]
  $ciphertext = [byte[]]$Blob[40..($Blob.Length - 33)]; $storedTag = [byte[]]$Blob[($Blob.Length - 32)..($Blob.Length - 1)]
  $passwordBytes = Get-PortablePasswordBytes $Password
  try {
    $keys = Get-PortableKeyMaterial $passwordBytes $salt
    try {
      $authenticatedData = [byte[]]$Blob[0..($Blob.Length - 33)]
      $hmac = New-Object Security.Cryptography.HMACSHA256(,([byte[]]$keys[32..63]))
      try { $computedTag = $hmac.ComputeHash($authenticatedData) } finally { $hmac.Dispose() }
      $difference = 0
      for ($index = 0; $index -lt 32; $index++) { $difference = $difference -bor ($storedTag[$index] -bxor $computedTag[$index]) }
      if ($difference -ne 0) { throw 'The password is incorrect or the credential file is corrupt.' }
      $aes = [Security.Cryptography.Aes]::Create(); $aes.Key = [byte[]]$keys[0..31]; $aes.IV = $iv
      try { $decryptor = $aes.CreateDecryptor(); try { return $decryptor.TransformFinalBlock($ciphertext, 0, $ciphertext.Length) } finally { $decryptor.Dispose() } } finally { $aes.Dispose() }
    } finally { [Array]::Clear($keys, 0, $keys.Length) }
  } finally { [Array]::Clear($passwordBytes, 0, $passwordBytes.Length) }
}

# ------------------------------------------------------------------------
#  Common portable password
#
#  The four assistants share one password. The first launcher that has to
#  save credentials asks for it twice and stores portatil.passcheck next to
#  this file (an encrypted known value, no credentials). Every later prompt
#  is checked against it, so a typo never locks credentials behind a
#  different password.
# ------------------------------------------------------------------------

$PortablePasswordCheck = Join-Path $PSScriptRoot 'portatil.passcheck'
$PortablePasswordCheckValue = [Text.Encoding]::ASCII.GetBytes('portatil-password-check')

# Reads and clears the password environment variables so the assistant
# child process never inherits them. PORTATIL_PASSWORD is the common one;
# the per-assistant names are kept for existing automation.
function Pop-PortableEnvPassword {
  param([string[]]$Names = @())
  $found = $null
  foreach ($name in @('PORTATIL_PASSWORD') + $Names) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($null -eq $found -and -not [string]::IsNullOrEmpty($value)) {
      $found = ConvertTo-SecureString $value -AsPlainText -Force
    }
    # Remove-Item, not SetEnvironmentVariable($name, $null): PowerShell 7
    # would still pass the name, empty, to child processes.
    Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
  }
  return $found
}

function Read-PortableSecret {
  param([string]$Prompt)
  $secret = Read-Host -AsSecureString -Prompt $Prompt
  if ($null -eq $secret -or $secret.Length -eq 0) { throw 'No se introdujo ninguna contrasena.' }
  return $secret
}

function Test-PortableSecretsEqual {
  param([Security.SecureString]$First, [Security.SecureString]$Second)
  $a = Get-PortablePasswordBytes $First
  $b = Get-PortablePasswordBytes $Second
  try {
    if ($a.Length -ne $b.Length) { return $false }
    $difference = 0
    for ($index = 0; $index -lt $a.Length; $index++) { $difference = $difference -bor ($a[$index] -bxor $b[$index]) }
    return ($difference -eq 0)
  } finally { [Array]::Clear($a, 0, $a.Length); [Array]::Clear($b, 0, $b.Length) }
}

function Test-PortablePassword {
  param([Security.SecureString]$Password)
  try {
    $value = Unprotect-PortableData ([IO.File]::ReadAllBytes($PortablePasswordCheck)) $Password 'PORTPW02'
    return ([Text.Encoding]::ASCII.GetString($value) -eq [Text.Encoding]::ASCII.GetString($PortablePasswordCheckValue))
  } catch { return $false }
}

# Records $Password as the common password if none is recorded yet.
function Register-PortablePassword {
  param([Security.SecureString]$Password)
  if (Test-Path -LiteralPath $PortablePasswordCheck) { return }
  Write-PortablePrivateBytes $PortablePasswordCheck (Protect-PortableData $PortablePasswordCheckValue $Password 'PORTPW02')
}

# Returns the common password as a SecureString.
#   -Provided          value from -Password or the environment (not prompted)
#   -ForNewCredentials credentials are about to be saved for the first time;
#                      when no common password exists yet, ask for a new one
#                      twice instead of once
function Get-PortablePassword {
  param([string]$Tool, [Security.SecureString]$Provided = $null, [switch]$ForNewCredentials)

  if (Test-Path -LiteralPath $PortablePasswordCheck) {
    if ($null -ne $Provided) {
      if (Test-PortablePassword $Provided) { return $Provided }
      throw 'La contrasena proporcionada no es la contrasena comun del portable.'
    }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
      $candidate = Read-PortableSecret "[$Tool] Contrasena del portable"
      if (Test-PortablePassword $candidate) { return $candidate }
      Write-Host '  Contrasena incorrecta.'
    }
    throw 'Contrasena incorrecta.'
  }

  if ($null -ne $Provided) {
    if ($ForNewCredentials) { Register-PortablePassword $Provided }
    return $Provided
  }

  if (-not $ForNewCredentials) {
    # Credentials encrypted before portatil.passcheck existed; decrypting
    # them validates the password and the launcher then registers it.
    return Read-PortableSecret "[$Tool] Contrasena del portable"
  }

  Write-Host ''
  Write-Host "[$Tool] Es la primera vez que se guardan credenciales en este portable."
  Write-Host "[$Tool] Elige la contrasena comun: la usaran los cuatro asistentes."
  while ($true) {
    $first = Read-PortableSecret 'Nueva contrasena del portable'
    $second = Read-PortableSecret 'Repite la contrasena'
    if (Test-PortableSecretsEqual $first $second) {
      Register-PortablePassword $first
      return $first
    }
    Write-Host '  Las contrasenas no coinciden. Intentalo de nuevo.'
  }
}

# Restricts a plaintext credential file to the current user. Best effort:
# exFAT/FAT32 pendrives have no ACLs and icacls fails there.
function Set-PortableFileAcl {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  try {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $Path /inheritance:r /grant:r "*$($sid):(F)" 2>$null | Out-Null
  } catch { }
}
