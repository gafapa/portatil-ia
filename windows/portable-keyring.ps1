# Moving credentials in and out of the Windows Credential Manager.
#
# Some assistants (Antigravity) keep their login in the Credential Manager
# instead of a file, which would leave it on the host PC. The launcher
# "shuttles" those entries: the portable's entries are written to the
# Credential Manager only while the assistant runs, then read back,
# encrypted into the portable, and deleted. Entries the host PC already
# had under the same names are moved aside while the portable runs and
# restored afterwards, so the host keeps its own login and the portable
# never uses it.
#
#   Prefix             entries used by the assistant, for example 'gemini:'
#   portatil-respaldo:<target>   host entry moved aside during a session
#   portatil-pendiente:<target>  portable entry that could not be encrypted
#                                at exit; encrypted on the next start
#
# Compatible with Windows PowerShell 5.1.

if (-not ('PortatilCredentialStore' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class PortatilCredentialStore {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  private struct CREDENTIAL {
    public uint Flags;
    public uint Type;
    public string TargetName;
    public string Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public uint CredentialBlobSize;
    public IntPtr CredentialBlob;
    public uint Persist;
    public uint AttributeCount;
    public IntPtr Attributes;
    public string TargetAlias;
    public string UserName;
  }

  [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern bool CredEnumerateW(string filter, uint flags, out uint count, out IntPtr credentials);
  [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern bool CredWriteW(ref CREDENTIAL credential, uint flags);
  [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern bool CredDeleteW(string target, uint type, uint flags);
  [DllImport("advapi32.dll")]
  private static extern void CredFree(IntPtr buffer);

  public class Entry {
    public string Target;
    public string User;
    public byte[] Blob;
    public uint Persist;
    public uint Type;
  }

  private const int ERROR_NOT_FOUND = 1168;

  public static List<Entry> List(string filter) {
    var result = new List<Entry>();
    uint count;
    IntPtr buffer;
    if (!CredEnumerateW(filter, 0, out count, out buffer)) {
      int error = Marshal.GetLastWin32Error();
      if (error == ERROR_NOT_FOUND) return result;
      throw new System.ComponentModel.Win32Exception(error);
    }
    try {
      for (int i = 0; i < count; i++) {
        IntPtr item = Marshal.ReadIntPtr(buffer, i * IntPtr.Size);
        var c = (CREDENTIAL)Marshal.PtrToStructure(item, typeof(CREDENTIAL));
        var blob = new byte[c.CredentialBlobSize];
        if (c.CredentialBlobSize > 0) Marshal.Copy(c.CredentialBlob, blob, 0, (int)c.CredentialBlobSize);
        result.Add(new Entry { Target = c.TargetName, User = c.UserName, Blob = blob, Persist = c.Persist, Type = c.Type });
      }
    } finally {
      CredFree(buffer);
    }
    return result;
  }

  public static void Write(Entry e) {
    var c = new CREDENTIAL();
    c.Type = e.Type == 0 ? 1u : e.Type;
    c.TargetName = e.Target;
    c.UserName = e.User;
    c.Persist = e.Persist == 0 ? 2u : e.Persist;
    byte[] blob = e.Blob ?? new byte[0];
    c.CredentialBlobSize = (uint)blob.Length;
    c.CredentialBlob = Marshal.AllocHGlobal(Math.Max(blob.Length, 1));
    try {
      Marshal.Copy(blob, 0, c.CredentialBlob, blob.Length);
      if (!CredWriteW(ref c, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    } finally {
      for (int i = 0; i < blob.Length; i++) Marshal.WriteByte(c.CredentialBlob, i, 0);
      Marshal.FreeHGlobal(c.CredentialBlob);
    }
  }

  public static bool Delete(string target, uint type) {
    if (CredDeleteW(target, type == 0 ? 1u : type, 0)) return true;
    int error = Marshal.GetLastWin32Error();
    if (error == ERROR_NOT_FOUND) return false;
    throw new System.ComponentModel.Win32Exception(error);
  }
}
'@
}

$PortableKeyringBackupPrefix = 'portatil-respaldo:'
$PortableKeyringPendingPrefix = 'portatil-pendiente:'

# Entries whose target starts with $Prefix.
function Get-PortableKeyringEntries {
  param([string]$Prefix)
  return @([PortatilCredentialStore]::List("$Prefix*"))
}

function Move-PortableKeyringEntry {
  param($Entry, [string]$NewTarget)
  $copy = New-Object PortatilCredentialStore+Entry
  $copy.Target = $NewTarget; $copy.User = $Entry.User; $copy.Blob = $Entry.Blob
  $copy.Persist = $Entry.Persist; $copy.Type = $Entry.Type
  [PortatilCredentialStore]::Write($copy)
  [void][PortatilCredentialStore]::Delete($Entry.Target, $Entry.Type)
}

# Serializable form of the entries (for the encrypted bundle).
function ConvertTo-PortableKeyringData {
  param($Entries, [string]$StripPrefix = '')
  $list = @()
  foreach ($e in $Entries) {
    $target = $e.Target
    if ($StripPrefix -and $target.StartsWith($StripPrefix)) { $target = $target.Substring($StripPrefix.Length) }
    $list += [ordered]@{ target = $target; usuario = $e.User; blob = [Convert]::ToBase64String($e.Blob); persist = [int]$e.Persist; tipo = [int]$e.Type }
  }
  # Unrolled on purpose: callers wrap the result in @().
  return $list
}

function Write-PortableKeyringData {
  param($Data)
  foreach ($d in $Data) {
    $e = New-Object PortatilCredentialStore+Entry
    $e.Target = [string]$d.target; $e.User = [string]$d.usuario
    $e.Blob = [Convert]::FromBase64String([string]$d.blob)
    $e.Persist = [uint32]$d.persist; $e.Type = [uint32]$d.tipo
    [PortatilCredentialStore]::Write($e)
  }
}

# Moves the host's own entries aside so the portable never uses them.
# Backups that already exist come from a session that did not finish;
# they are the host's originals and are kept as they are.
function Save-HostKeyringEntries {
  param([string]$Prefix)
  foreach ($e in (Get-PortableKeyringEntries $Prefix)) {
    $backup = $PortableKeyringBackupPrefix + $e.Target
    if (@(Get-PortableKeyringEntries $backup).Count -gt 0) { continue }
    Move-PortableKeyringEntry $e $backup
  }
}

# Puts the host's entries back, replacing whatever is under their names.
function Restore-HostKeyringEntries {
  param([string]$Prefix)
  foreach ($b in (Get-PortableKeyringEntries ($PortableKeyringBackupPrefix + $Prefix))) {
    $original = $b.Target.Substring($PortableKeyringBackupPrefix.Length)
    [void][PortatilCredentialStore]::Delete($original, $b.Type)
    Move-PortableKeyringEntry $b $original
  }
}

function Remove-PortableKeyringEntries {
  param($Entries)
  foreach ($e in $Entries) { [void][PortatilCredentialStore]::Delete($e.Target, $e.Type) }
}
