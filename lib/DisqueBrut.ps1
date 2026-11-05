# Accès bas niveau : lecture/écriture brute, table de partitions (IOCTL), verrouillage de volume.
# Structures Windows (x64) utilisées, d'après winioctl.h :
#   DRIVE_LAYOUT_INFORMATION_EX : PartitionStyle(4) PartitionCount(4) union GPT/MBR(40) -> entrées à l'octet 48
#   PARTITION_INFORMATION_EX (144 octets) : Style(4) pad(4) StartingOffset(8)@8 PartitionLength(8)@16
#       PartitionNumber(4)@24 RewritePartition(1)@28 IsServicePartition(1)@29 pad(2) union@32
#       GPT : PartitionType(16)@32 PartitionId(16)@48 Attributes(8)@64 Name(72)@72
#       MBR : PartitionType(1)@32 BootIndicator(1)@33 Recognized(1)@34 pad(1) HiddenSectors(4)@36 PartitionId(16)@40

Set-StrictMode -Version 3

if (-not ('DP.Brut' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace DP {
public static class Brut {
    const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000;
    const uint SHARE_RW = 3, OPEN_EXISTING = 3, WRITE_THROUGH = 0x80000000;
    public const uint IOCTL_DISK_GET_DRIVE_LAYOUT_EX = 0x00070050;
    public const uint IOCTL_DISK_SET_DRIVE_LAYOUT_EX = 0x0007C054;
    public const uint IOCTL_DISK_UPDATE_PROPERTIES   = 0x00070140;
    public const uint FSCTL_LOCK_VOLUME     = 0x00090018;
    public const uint FSCTL_UNLOCK_VOLUME   = 0x0009001C;
    public const uint FSCTL_DISMOUNT_VOLUME = 0x00090020;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inBuf, int inSize, byte[] outBuf, int outSize, out int returned, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFilePointerEx(SafeFileHandle h, long dist, out long newPos, uint method);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(SafeFileHandle h, byte[] buf, int n, out int done, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(SafeFileHandle h, byte[] buf, int n, out int done, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FlushFileBuffers(SafeFileHandle h);

    static void Err(string what) { throw new Win32Exception(Marshal.GetLastWin32Error(), what); }

    public static SafeFileHandle Ouvrir(string path, bool write) {
        SafeFileHandle h = CreateFileW(path, GENERIC_READ | (write ? GENERIC_WRITE : 0u), SHARE_RW, IntPtr.Zero,
                                       OPEN_EXISTING, write ? WRITE_THROUGH : 0u, IntPtr.Zero);
        if (h.IsInvalid) Err("Ouverture de " + path);
        return h;
    }
    static void Seek(SafeFileHandle h, long offset) {
        long p; if (!SetFilePointerEx(h, offset, out p, 0)) Err("Positionnement à " + offset);
    }
    public static byte[] Lire(SafeFileHandle h, long offset, int count) {
        Seek(h, offset);
        byte[] buf = new byte[count]; int n;
        if (!ReadFile(h, buf, count, out n, IntPtr.Zero)) Err("Lecture à " + offset);
        if (n != count) throw new Exception("Lecture incomplète à " + offset + " (" + n + "/" + count + ")");
        return buf;
    }
    public static void Ecrire(SafeFileHandle h, long offset, byte[] data) {
        Seek(h, offset); int n;
        if (!WriteFile(h, data, data.Length, out n, IntPtr.Zero)) Err("Écriture à " + offset);
        if (n != data.Length) throw new Exception("Écriture incomplète à " + offset);
    }
    public static void Vider(SafeFileHandle h) { if (!FlushFileBuffers(h)) Err("Vidage du cache disque"); }
    public static byte[] Ioctl(SafeFileHandle h, uint code, byte[] input, int outSize) {
        byte[] outBuf = outSize > 0 ? new byte[outSize] : null; int ret;
        if (!DeviceIoControl(h, code, input, input == null ? 0 : input.Length, outBuf, outSize, out ret, IntPtr.Zero))
            Err("DeviceIoControl 0x" + code.ToString("X8"));
        if (outBuf == null) return new byte[0];
        byte[] r = new byte[ret]; Array.Copy(outBuf, r, ret); return r;
    }
}
}
'@
}

$script:TailleEnteteLayout = 48
$script:TailleEntreeLayout = 144

function Read-LayoutBrut([int]$Disque) {
    $h = [DP.Brut]::Ouvrir("\\.\PhysicalDrive$Disque", $false)
    try { return , ([DP.Brut]::Ioctl($h, [DP.Brut]::IOCTL_DISK_GET_DRIVE_LAYOUT_EX, $null, 48 + 144 * 256)) }
    finally { $h.Dispose() }
}

function ConvertFrom-LayoutBrut([byte[]]$B) {
    $style = [BitConverter]::ToUInt32($B, 0)
    $n = [BitConverter]::ToUInt32($B, 4)
    $e = for ($i = 0; $i -lt $n; $i++) {
        $o = 48 + 144 * $i
        [pscustomobject]@{
            index  = $i
            offset = [BitConverter]::ToInt64($B, $o + 8)
            taille = [BitConverter]::ToInt64($B, $o + 16)
            numero = [BitConverter]::ToUInt32($B, $o + 24)
            id     = if ($style -eq 1) { ([guid][byte[]]$B[($o + 48)..($o + 63)]).ToString('B') } else { $null }
        }
    }
    return [pscustomobject]@{ style = @('MBR', 'GPT', 'RAW')[$style]; nombre = $n; entrees = @($e) }
}

function Set-OffsetLayout {
    <# Renvoie une copie du layout où la partition $Numero commence à $Nouvel. Fonction pure (testable). #>
    param([byte[]]$B, [uint32]$Numero, [int64]$Nouvel, [int]$TailleSecteur)
    $n = [BitConverter]::ToUInt32($B, 4)
    $style = [BitConverter]::ToUInt32($B, 0)
    $taille = 48 + 144 * $n
    $c = New-Object byte[] $taille
    [Array]::Copy($B, $c, $taille)
    $trouve = $false
    for ($i = 0; $i -lt $n; $i++) {
        $o = 48 + 144 * $i
        $c[$o + 28] = 1   # RewritePartition : obligatoire pour toutes les entrées lors d'un SET
        $num = [BitConverter]::ToUInt32($c, $o + 24)
        $len = [BitConverter]::ToInt64($c, $o + 16)
        if ($num -eq $Numero -and $len -gt 0) {
            [Array]::Copy([BitConverter]::GetBytes([int64]$Nouvel), 0, $c, $o + 8, 8)
            if ($style -eq 0) {
                [Array]::Copy([BitConverter]::GetBytes([uint32]($Nouvel / $TailleSecteur)), 0, $c, $o + 36, 4)
            }
            $trouve = $true
        }
    }
    if (-not $trouve) { throw "Partition n°$Numero absente de la table." }
    return , $c
}

function Write-LayoutBrut([int]$Disque, [byte[]]$B) {
    $h = [DP.Brut]::Ouvrir("\\.\PhysicalDrive$Disque", $true)
    try {
        [void][DP.Brut]::Ioctl($h, [DP.Brut]::IOCTL_DISK_SET_DRIVE_LAYOUT_EX, $B, 0)
        [void][DP.Brut]::Ioctl($h, [DP.Brut]::IOCTL_DISK_UPDATE_PROPERTIES, $null, 0)
    } finally { $h.Dispose() }
}

function Lock-Volume([string]$CheminVolume) {
    <# Verrouille et démonte un volume ; garder le handle ouvert tant que dure l'opération. #>
    $c = $CheminVolume.TrimEnd('\')
    $h = [DP.Brut]::Ouvrir($c, $true)
    try {
        [void][DP.Brut]::Ioctl($h, [DP.Brut]::FSCTL_LOCK_VOLUME, $null, 0)
        [void][DP.Brut]::Ioctl($h, [DP.Brut]::FSCTL_DISMOUNT_VOLUME, $null, 0)
    } catch { $h.Dispose(); throw "Impossible de verrouiller $c (volume en cours d'utilisation ?) : $($_.Exception.Message)" }
    return $h
}

function Update-SecteurBoot {
    <# Met à jour le champ « hidden sectors » (0x1C) du secteur de démarrage NTFS/FAT32 et de sa copie de secours.
       Fonction pure : prend et renvoie des secteurs ; la lecture/écriture est faite par l'appelant. #>
    param([byte[]]$Secteur, [int64]$NouvelOffset)
    $oem = [Text.Encoding]::ASCII.GetString($Secteur, 3, 8)
    $fat32 = [Text.Encoding]::ASCII.GetString($Secteur, 82, 8)
    if ($oem -ne 'NTFS    ' -and $fat32 -ne 'FAT32   ') { return $null }   # BitLocker, ReFS, autre : rien à faire
    $bps = [BitConverter]::ToUInt16($Secteur, 11)
    $c = [byte[]]$Secteur.Clone()
    [Array]::Copy([BitConverter]::GetBytes([uint32]($NouvelOffset / $bps)), 0, $c, 0x1C, 4)
    return , $c
}

function Get-PositionSecoursBoot([byte[]]$Secteur) {
    <# Position (relative au volume) de la copie de secours du secteur de démarrage. #>
    $bps = [BitConverter]::ToUInt16($Secteur, 11)
    if ([Text.Encoding]::ASCII.GetString($Secteur, 3, 8) -eq 'NTFS    ') { return [int64][BitConverter]::ToInt64($Secteur, 0x28) * $bps }
    if ([Text.Encoding]::ASCII.GetString($Secteur, 82, 8) -eq 'FAT32   ') { return [int64][BitConverter]::ToUInt16($Secteur, 0x32) * $bps }
    return $null
}
