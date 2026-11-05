# Fonctions partagées (chargées par dot-sourcing : . "$PSScriptRoot\lib\Commun.ps1").
# Règles : aucune analyse de texte traduit (GUID, XML, API, codes de sortie uniquement) ;
# toute écriture passe par Invoke-Etape (simulation par défaut).

Set-StrictMode -Version 3

$script:GPT = @{
    EFI      = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    MSR      = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
    Basic    = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    Recovery = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
}
$script:AttributsRecovery = '0x8000000000000001'   # requis + pas de lettre (procédure Microsoft)
$script:Executer = $false
$script:FichierLog = $null

function Test-Admin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-WinPE { return (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT') }

function Format-Taille([double]$o) {
    if ([math]::Abs($o) -ge 1TB) { return '{0:N2} To' -f ($o / 1TB) }
    if ([math]::Abs($o) -ge 1GB) { return '{0:N2} Go' -f ($o / 1GB) }
    return '{0:N0} Mo' -f ($o / 1MB)
}

function Get-Firmware {
    # API GetFirmwareType (Windows 8+, sans droits) : 1 = BIOS, 2 = UEFI.
    try {
        if (-not ('DP.Firmware' -as [type])) {
            Add-Type -Namespace DP -Name Firmware -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool GetFirmwareType(out int t);'
        }
        $t = 0
        if ([DP.Firmware]::GetFirmwareType([ref]$t)) {
            if ($t -eq 2) { return 'UEFI' } elseif ($t -eq 1) { return 'BIOS' }
        }
    } catch { }
    return 'INCONNU'
}

function Get-LettrePartition($p) {
    if ($p.DriveLetter -and $p.DriveLetter -ne [char]0) { return "$($p.DriveLetter):" }
    return ''
}

function Find-PartitionsWindows {
    <# Partitions contenant une installation Windows (fonctionne aussi sous WinPE, où IsBoot est faux). #>
    param([int]$Disque = -1)
    $parts = if ($Disque -ge 0) { Get-Partition -DiskNumber $Disque } else { Get-Partition }
    foreach ($p in $parts) {
        $l = Get-LettrePartition $p
        if ($l -and (Test-Path -LiteralPath "$l\Windows\System32\config\SYSTEM")) { $p }
    }
}

function Get-WinRE {
    <# Lit ReAgent.xml (XML, indépendant de la langue, contrairement à reagentc /info). #>
    param([string]$RacineWindows = $env:SystemRoot)
    $f = Join-Path $RacineWindows 'System32\Recovery\ReAgent.xml'
    $r = [ordered]@{ fichier = $f; lu = $false; active = $null; offset = $null; guid_disque = $null; chemin = $null; erreur = $null }
    try {
        [xml]$x = Get-Content -LiteralPath $f -Raw -ErrorAction Stop
        $r.lu = $true
        $loc = $x.SelectSingleNode('//WinreLocation')
        $bcd = $x.SelectSingleNode('//WinreBCD')
        $id = if ($bcd) { $bcd.GetAttribute('id') } else { '' }
        $r.active = [bool]($id -and $id -ne '{00000000-0000-0000-0000-000000000000}')
        if ($loc) {
            $o = $loc.GetAttribute('offset')
            if ($o) { $r.offset = [int64]$o }
            $r.guid_disque = $loc.GetAttribute('guid')
            $r.chemin = $loc.GetAttribute('path')
        }
    } catch { $r.erreur = $_.Exception.Message }
    return $r
}

function Get-BitLocker([string]$Lettre) {
    $Lettre = $Lettre.TrimEnd(':')
    $r = [ordered]@{ lu = $false; protection = $null; conversion = $null; erreur = $null }
    try {
        $v = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume `
            -Filter "DriveLetter='$($Lettre):'" -ErrorAction Stop
        if ($v) {
            $r.lu = $true
            $r.protection = @{ 0 = 'désactivée'; 1 = 'ACTIVE'; 2 = 'inconnue' }[[int]$v.ProtectionStatus]
            $r.conversion = @{ 0 = 'non chiffré'; 1 = 'chiffré'; 2 = 'chiffrement en cours'; 3 = 'déchiffrement en cours'
                               4 = 'chiffrement en pause'; 5 = 'déchiffrement en pause' }[[int]$v.ConversionStatus]
        }
    } catch { $r.erreur = 'droits administrateur requis (ou composant BitLocker absent)' }
    return $r
}

function Get-BcdEntree([string]$Id) {
    # Les noms de champs de bcdedit (device, osdevice, path…) ne sont pas traduits ; seuls les titres le sont.
    $r = [ordered]@{ lu = $false }
    $out = & bcdedit.exe /enum $Id /v 2>&1
    if ($LASTEXITCODE -ne 0) { $r.erreur = 'droits administrateur requis'; return $r }
    $r.lu = $true
    foreach ($ligne in $out) {
        if ("$ligne" -match '^(identifier|device|osdevice|path|recoverysequence|recoveryenabled)\s+(.+)$') {
            $r[$Matches[1]] = $Matches[2].Trim()
        }
    }
    return $r
}

# --- Journal et exécution contrôlée --------------------------------------------------------------
function Write-Log {
    param([string]$Texte, [ValidateSet('INFO', 'OK', 'ATTENTION', 'ERREUR', 'ETAPE', 'SIMULATION')][string]$Niveau = 'INFO')
    $c = @{ INFO = 'Gray'; OK = 'Green'; ATTENTION = 'Yellow'; ERREUR = 'Red'; ETAPE = 'Cyan'; SIMULATION = 'Magenta' }[$Niveau]
    Write-Host ("  [{0}] {1}" -f $Niveau, $Texte) -ForegroundColor $c
    if ($script:FichierLog) {
        Add-Content -LiteralPath $script:FichierLog -Value ("{0} [{1}] {2}" -f (Get-Date -Format 's'), $Niveau, $Texte) -Encoding UTF8
    }
}

function Invoke-Etape {
    <# Exécute une étape qui modifie le système, ou l'affiche seulement en mode simulation. #>
    param([Parameter(Mandatory)][string]$Nom, [Parameter(Mandatory)][scriptblock]$Action)
    if (-not $script:Executer) { Write-Log $Nom 'SIMULATION'; return $null }
    Write-Log $Nom 'ETAPE'
    return (& $Action)
}

function Confirm-Operation([string]$Resume) {
    if (-not $script:Executer) { return $true }
    Write-Host ''
    Write-Host "  $Resume" -ForegroundColor Yellow
    $r = Read-Host '  Tapez OUI (en majuscules) pour lancer'
    return ($r -ceq 'OUI')
}

function Invoke-Externe {
    <# Lance un exécutable, journalise sa sortie, lève une erreur si le code de sortie n'est pas 0. #>
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @(), [switch]$Tolerant)
    $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    if ($script:FichierLog) { Add-Content -LiteralPath $script:FichierLog -Value ("> $Exe $($Arguments -join ' ') (code $code)`r`n" + ($out -join "`r`n")) -Encoding UTF8 }
    if ($code -ne 0 -and -not $Tolerant) { throw "$Exe a échoué (code $code) : $(($out | Select-Object -Last 3) -join ' | ')" }
    return [pscustomobject]@{ code = $code; sortie = $out }
}

function Invoke-Diskpart([string[]]$Lignes) {
    $f = Join-Path $env:TEMP ("dp_{0}.txt" -f ([guid]::NewGuid().ToString('N')))
    Set-Content -LiteralPath $f -Value $Lignes -Encoding ASCII
    try { return (Invoke-Externe -Exe 'diskpart.exe' -Arguments @('/s', $f)) } finally { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
}

function Get-LettreLibre([string]$Preferees = 'RSTUVWQPONML') {
    $prises = @((Get-PSDrive -PSProvider FileSystem).Name) + @(Get-Volume | Where-Object DriveLetter | ForEach-Object { "$($_.DriveLetter)" })
    foreach ($c in $Preferees.ToCharArray()) { if ($prises -notcontains "$c") { return "$c" } }
    throw 'Aucune lettre de lecteur libre.'
}

function Mount-PartitionTemporaire($Partition) {
    <# Attribue une lettre temporaire ; renvoie "X:" et l'info pour la retirer ensuite. #>
    $l = Get-LettrePartition $Partition
    if ($l) { return [pscustomobject]@{ lettre = $l; temporaire = $false } }
    $c = Get-LettreLibre
    Add-PartitionAccessPath -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -AccessPath "$($c):\"
    return [pscustomobject]@{ lettre = "$($c):"; temporaire = $true; disque = $Partition.DiskNumber; numero = $Partition.PartitionNumber }
}

function Dismount-PartitionTemporaire($Montage) {
    if ($Montage -and $Montage.temporaire) {
        Remove-PartitionAccessPath -DiskNumber $Montage.disque -PartitionNumber $Montage.numero -AccessPath "$($Montage.lettre)\" -ErrorAction SilentlyContinue
    }
}

# --- Sauvegardes ------------------------------------------------------------------------------------
function New-DossierSauvegarde([string]$Base, [string]$Nom) {
    $d = Join-Path $Base ("{0}_{1}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $Nom)
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    $script:FichierLog = Join-Path $d 'journal.log'
    return $d
}

function Save-EtatDisque {
    <# Sauvegarde la table de partitions (brute + JSON), le BCD et ReAgent.xml avant toute modification. #>
    param([int]$Disque, [string]$Dossier, [string]$RacineWindows = $env:SystemRoot)
    $disk = Get-Disk -Number $Disque
    $parts = Get-Partition -DiskNumber $Disque | Select-Object PartitionNumber, Offset, Size, GptType, MbrType, Guid, DriveLetter, IsBoot, IsSystem, IsActive
    [ordered]@{ disque = ($disk | Select-Object Number, FriendlyName, SerialNumber, PartitionStyle, Guid, Signature, Size, LogicalSectorSize); partitions = $parts } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Dossier 'disposition.json') -Encoding UTF8

    # Début et fin du disque en brut : MBR protecteur + GPT principal, GPT de secours.
    try {
        $h = [DP.Brut]::Ouvrir("\\.\PhysicalDrive$Disque", $false)
        try {
            [IO.File]::WriteAllBytes((Join-Path $Dossier 'disque_debut_1Mo.bin'), [DP.Brut]::Lire($h, 0, 1MB))
            [IO.File]::WriteAllBytes((Join-Path $Dossier 'disque_fin_1Mo.bin'), [DP.Brut]::Lire($h, [int64]$disk.Size - 1MB, 1MB))
        } finally { $h.Dispose() }
        Write-Log 'Table de partitions sauvegardée (brut + JSON).' 'OK'
    } catch { Write-Log "Sauvegarde brute impossible : $($_.Exception.Message)" 'ATTENTION' }

    if (-not (Test-WinPE)) {
        $r = Invoke-Externe -Exe 'bcdedit.exe' -Arguments @('/export', (Join-Path $Dossier 'bcd.sauvegarde')) -Tolerant
        if ($r.code -eq 0) { Write-Log 'BCD exporté (restauration : bcdedit /import).' 'OK' } else { Write-Log 'Export du BCD impossible.' 'ATTENTION' }
    }
    $xml = Join-Path $RacineWindows 'System32\Recovery\ReAgent.xml'
    if (Test-Path -LiteralPath $xml) { Copy-Item -LiteralPath $xml -Destination $Dossier }
}

# --- Vérification du démarrage ------------------------------------------------------------------------
function Test-Demarrage {
    <# Vérifie la chaîne de démarrage de la Windows en cours. Renvoie une liste de contrôles (ok = $true/$false/$null). #>
    $res = New-Object System.Collections.Generic.List[object]
    function Add-R([string]$code, $ok, [string]$texte) { $res.Add([pscustomobject]@{ code = $code; ok = $ok; texte = $texte }) }

    $fw = Get-Firmware
    $sysPart = Get-Partition | Where-Object IsSystem | Select-Object -First 1
    if (-not $sysPart) { Add-R 'SYS' $false 'Aucune partition système (EFI / active) détectée.' }
    else {
        $vol = $null; try { $vol = $sysPart | Get-Volume -ErrorAction Stop } catch { }
        if ($vol -and $vol.Path) {
            $boot = if ($fw -eq 'UEFI') { 'EFI\Microsoft\Boot\bootmgfw.efi' } else { 'bootmgr' }
            $bcd = if ($fw -eq 'UEFI') { 'EFI\Microsoft\Boot\BCD' } else { 'Boot\BCD' }
            $okBoot = Test-Path -LiteralPath (Join-Path $vol.Path $boot)
            $okBcd = Test-Path -LiteralPath (Join-Path $vol.Path $bcd)
            Add-R 'SYS-FICHIERS' ($okBoot -and $okBcd) "Gestionnaire de démarrage ($boot) et magasin BCD présents sur la partition système."
        } else { Add-R 'SYS-FICHIERS' $null 'Contenu de la partition système non lisible (droits administrateur requis).' }
    }

    $os = Get-BcdEntree '{current}'
    if ($os.lu) {
        $dev = if ($os.Contains('osdevice')) { $os['osdevice'] } else { '' }
        Add-R 'BCD-OS' ($dev -match "partition=$([regex]::Escape($env:SystemDrive))") "Entrée BCD de la Windows en cours : osdevice = $dev"
    } else { Add-R 'BCD-OS' $null 'BCD non lisible (droits administrateur requis).' }

    $wre = Get-WinRE
    if (-not $wre.lu) { Add-R 'WINRE' $null 'ReAgent.xml non lisible.' }
    elseif (-not $wre.active) { Add-R 'WINRE' $false 'WinRE désactivé.' }
    elseif ($wre.offset) {
        $cible = Get-Partition | Where-Object { [int64]$_.Offset -eq $wre.offset } | Select-Object -First 1
        Add-R 'WINRE' ([bool]$cible) $(if ($cible) { "WinRE actif sur la partition n°$($cible.PartitionNumber)." } else { "WinRE pointe vers un offset inexistant ($($wre.offset))." })
    } else { Add-R 'WINRE' $true 'WinRE actif (sur la partition Windows).' }

    $bl = Get-BitLocker $env:SystemDrive
    if ($bl.lu) { Add-R 'BITLOCKER' $true "BitLocker : protection $($bl.protection), $($bl.conversion)." }
    return $res
}

function Show-Controles($Controles) {
    foreach ($c in $Controles) {
        $n = if ($c.ok -eq $true) { 'OK' } elseif ($c.ok -eq $false) { 'ERREUR' } else { 'ATTENTION' }
        Write-Log ("{0} : {1}" -f $c.code, $c.texte) $n
    }
}
