#Requires -Version 5.1
<#
.SYNOPSIS
    Analyse en lecture seule du disque système Windows avant toute modification de partitions.
.DESCRIPTION
    Relève la disposition des partitions, l'espace libre, BitLocker, WinRE et la chaîne de démarrage (BCD),
    puis liste ce qui bloque, ce qui est faisable sous Windows et ce qui exige un démarrage WinPE.
    Ne modifie rien. Écrit un rapport JSON dans .\rapports\.
.EXAMPLE
    .\Analyse-Partitions.ps1            # analyse du disque système
    .\Analyse-Partitions.ps1 -Disque 1  # analyse d'un autre disque
#>
[CmdletBinding()]
param(
    [int]$Disque = -1,
    [string]$DossierRapport = ''
)

$ErrorActionPreference = 'Stop'

$Racine = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Racine 'lib\Commun.ps1')
$MiB = 1MB
$Tolerance = 2MB   # trou inférieur = alignement, pas de l'espace libre exploitable

function Test-ContientWindows($p) {
    $l = Get-LettrePartition $p
    return [bool]($p.IsBoot -or ($l -and (Test-Path -LiteralPath "$l\Windows\System32\config\SYSTEM")))
}

function Get-Role($p, [string]$style) {
    if ($style -eq 'GPT') {
        switch ($p.GptType) {
            $GPT.EFI      { return 'EFI' }
            $GPT.MSR      { return 'MSR' }
            $GPT.Recovery { return 'Recovery' }
            $GPT.Basic    { if (Test-ContientWindows $p) { return 'Windows' } else { return 'Données' } }
            default       { return 'Autre' }
        }
    }
    if (Test-ContientWindows $p) { return 'Windows' }
    if ($p.IsActive -or ($p.IsSystem -and -not (Test-WinPE))) { return 'Système (MBR)' }
    if ($p.MbrType -eq 0x27) { return 'Recovery' }
    return 'Données'
}

function Get-Segments($disk, $parts) {
    # Liste ordonnée partitions + espaces libres (≥ tolérance) sur toute la surface du disque.
    $seg = New-Object System.Collections.Generic.List[object]
    $debutUtile = 1MB
    $finUtile = [int64]$disk.Size - $(if ($disk.PartitionStyle -eq 'GPT') { 1MB } else { 0 })  # GPT de secours
    $curseur = [int64]$debutUtile
    foreach ($p in ($parts | Sort-Object Offset)) {
        if ($p.Offset - $curseur -ge $Tolerance) {
            $seg.Add([pscustomobject]@{ type = 'libre'; offset = $curseur; taille = $p.Offset - $curseur })
        }
        $seg.Add([pscustomobject]@{ type = 'partition'; offset = [int64]$p.Offset; taille = [int64]$p.Size; numero = $p.PartitionNumber })
        $curseur = [int64]$p.Offset + [int64]$p.Size
    }
    if ($finUtile - $curseur -ge $Tolerance) {
        $seg.Add([pscustomobject]@{ type = 'libre'; offset = $curseur; taille = $finUtile - $curseur })
    }
    return $seg
}

# =================================================================================================
if (-not $DossierRapport) { $DossierRapport = Join-Path $Racine 'rapports' }
$admin = Test-Admin
if (-not $admin) {
    Write-Warning 'Pas en administrateur : BitLocker, BCD et contenu de la partition EFI ne seront pas vérifiés.'
}

if ($Disque -lt 0) {
    if (Test-WinPE) { throw 'Sous WinPE, précisez -Disque <numéro> (Get-Disk pour la liste).' }
    $Disque = (Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':'))).DiskNumber
}
$disk = Get-Disk -Number $Disque
$parts = @(Get-Partition -DiskNumber $Disque | Sort-Object Offset)
$firmware = Get-Firmware

$partitions = foreach ($p in $parts) {
    $vol = $null
    try { $vol = $p | Get-Volume -ErrorAction Stop } catch { }
    [pscustomobject][ordered]@{
        numero      = $p.PartitionNumber
        role        = Get-Role $p $disk.PartitionStyle
        lettre      = if ($p.DriveLetter -and $p.DriveLetter -ne [char]0) { "$($p.DriveLetter):" } else { '' }
        offset      = [int64]$p.Offset
        taille      = [int64]$p.Size
        fin         = [int64]$p.Offset + [int64]$p.Size
        aligne_1Mo  = ($p.Offset % $MiB -eq 0)
        guid        = $p.Guid
        gpt_type    = $p.GptType
        fs          = if ($vol) { $vol.FileSystem } else { '' }
        libre_fs    = if ($vol) { [int64]$vol.SizeRemaining } else { $null }
        volume_path = if ($vol) { $vol.Path } else { '' }
        est_boot    = [bool]$p.IsBoot
        est_systeme = [bool]$p.IsSystem
    }
}
$partitions = @($partitions)
$segments = @(Get-Segments $disk $parts)

$win = $partitions | Where-Object role -eq 'Windows' | Select-Object -First 1
$sys = $partitions | Where-Object { $_.role -in 'EFI', 'Système (MBR)' } | Select-Object -First 1
$winre = if ($win -and $win.lettre) { Get-WinRE "$($win.lettre)\Windows" } else { Get-WinRE }
$enLigne = -not (Test-WinPE)
$bitlocker = if ($win -and $win.lettre) { Get-BitLocker $win.lettre.TrimEnd(':') } else { @{ lu = $false } }
$bcdMgr = if ($admin -and $enLigne) { Get-BcdEntree '{bootmgr}' } else { @{ lu = $false } }
$bcdOs = if ($admin -and $enLigne) { Get-BcdEntree '{current}' } else { @{ lu = $false } }

# --- Vérification de la chaîne de démarrage -------------------------------------------------------
$demarrage = [ordered]@{ fichier_boot = $null; fichier_boot_present = $null }
if ($sys -and $sys.volume_path -and $admin) {
    $f = if ($firmware -eq 'UEFI') { 'EFI\Microsoft\Boot\bootmgfw.efi' } else { 'bootmgr' }
    $demarrage.fichier_boot = $f
    $demarrage.fichier_boot_present = Test-Path -LiteralPath (Join-Path $sys.volume_path $f)
    $demarrage.bcd_present = Test-Path -LiteralPath (Join-Path $sys.volume_path $(if ($firmware -eq 'UEFI') { 'EFI\Microsoft\Boot\BCD' } else { 'Boot\BCD' }))
}

# --- Diagnostic ----------------------------------------------------------------------------------
$constats = New-Object System.Collections.Generic.List[object]
function Add-Constat([string]$niveau, [string]$code, [string]$texte, [string]$action = '') {
    $constats.Add([pscustomobject][ordered]@{ niveau = $niveau; code = $code; texte = $texte; action = $action })
}

if (-not $win) { Add-Constat 'INFO' 'DSK-000' "Ce disque ne contient pas la partition Windows en cours d'exécution." }

if ($win) {
    $i = [array]::IndexOf(@($segments | ForEach-Object { if ($_.type -eq 'partition') { $_.numero } else { -1 } }), $win.numero)
    $apres = if ($i -ge 0 -and $i + 1 -lt $segments.Count) { $segments[$i + 1] } else { $null }
    $avant = if ($i -gt 0) { $segments[$i - 1] } else { $null }

    if ($apres -and $apres.type -eq 'libre') {
        Add-Constat 'OK' 'EXT-001' "$(Format-Taille $apres.taille) libres juste après $($win.lettre) : extension possible sous Windows, sans redémarrage." `
            'Operations.ps1 -Action Agrandir (en ligne, sans risque pour le démarrage).'
    } elseif ($apres -and $apres.type -eq 'partition') {
        $p2 = $partitions | Where-Object numero -eq $apres.numero
        $libreDerriere = $segments | Where-Object { $_.type -eq 'libre' -and $_.offset -ge $p2.fin } | Measure-Object taille -Sum
        if ($p2.role -eq 'Recovery') {
            $txt = "La partition de récupération (n°$($p2.numero), $(Format-Taille $p2.taille)) est collée derrière $($win.lettre) : elle bloque son agrandissement."
            if ($libreDerriere.Sum -ge 1GB) {
                Add-Constat 'BLOQUANT' 'EXT-002' "$txt $(Format-Taille $libreDerriere.Sum) libres se trouvent derrière elle." `
                    'Operations.ps1 -Action DeplacerRecovery (en ligne : WinRE désactivé, Recovery recréée en fin de disque, C: agrandi, WinRE réactivé).'
            } else {
                Add-Constat 'INFO' 'EXT-003' "$txt Pas d'espace libre utile derrière elle (< 1 Go) : rien à récupérer pour l'instant."
            }
        } else {
            Add-Constat 'INFO' 'EXT-004' "La partition n°$($p2.numero) ($($p2.role)) suit $($win.lettre) : agrandir C: imposerait de la déplacer."
        }
    }
    if ($avant -and $avant.type -eq 'libre') {
        Add-Constat 'WINPE' 'MOV-001' "$(Format-Taille $avant.taille) libres AVANT $($win.lettre) : les récupérer impose de déplacer le début de C:." `
            'Clé WinPE : WinPE\Deplacer-Partition.ps1 -Direction Gauche, puis Operations.ps1 -Action Agrandir au redémarrage.'
    }
    if (-not $win.aligne_1Mo) {
        Add-Constat 'ATTENTION' 'ALN-001' "$($win.lettre) n'est pas alignée sur 1 Mo (performances SSD dégradées)." 'Réalignement possible uniquement hors ligne (WinPE).'
    }
}

if ($bitlocker.lu -and $bitlocker.protection -eq 'ACTIVE') {
    Add-Constat 'BLOQUANT' 'BLK-001' "BitLocker est actif sur $($win.lettre) ($($bitlocker.conversion))." `
        "Suspendre la protection (Suspend-BitLocker -RebootCount 1) avant toute modification, sinon la clé de récupération sera demandée au démarrage."
} elseif (-not $bitlocker.lu) {
    Add-Constat 'ATTENTION' 'BLK-000' 'État BitLocker non lu.' 'Relancer en administrateur.'
}

if ($disk.PartitionStyle -eq 'MBR') {
    Add-Constat 'ATTENTION' 'BCD-001' 'Disque MBR : le BCD repère Windows par signature de disque + position. Tout déplacement de C: casse le démarrage.' `
        'Après déplacement : bcdboot obligatoire (fait automatiquement par l''outil).'
    if ($disk.Size -gt 2TB) { Add-Constat 'ATTENTION' 'MBR-002' 'Disque MBR de plus de 2 To : la partie au-delà de 2 To est inutilisable.' 'Conversion GPT (mbr2gpt) envisageable.' }
} elseif ($disk.PartitionStyle -eq 'GPT') {
    Add-Constat 'OK' 'BCD-002' 'Disque GPT : le BCD repère Windows par GUID de partition. Un déplacement qui conserve les GUID ne casse pas le démarrage.'
}

if ($firmware -eq 'UEFI' -and $disk.PartitionStyle -ne 'GPT' -and $win) {
    Add-Constat 'ATTENTION' 'FW-001' 'Firmware UEFI mais disque système MBR (mode Legacy/CSM).'
}
$efi = $partitions | Where-Object role -eq 'EFI' | Select-Object -First 1
if ($disk.PartitionStyle -eq 'GPT' -and $win -and -not $efi) {
    Add-Constat 'BLOQUANT' 'EFI-001' 'Aucune partition EFI sur le disque système.' 'Créer une partition EFI (≥ 100 Mo, FAT32) puis bcdboot.'
} elseif ($efi -and $efi.taille -lt 100MB) {
    Add-Constat 'ATTENTION' 'EFI-002' "Partition EFI petite ($(Format-Taille $efi.taille)) : certaines mises à jour peuvent échouer." 'Recommandé : 260 Mo.'
}
if ($demarrage.fichier_boot_present -eq $false) {
    Add-Constat 'BLOQUANT' 'BOOT-001' "Fichier de démarrage absent : $($demarrage.fichier_boot)." 'Réparer : bcdboot C:\Windows /s <lettre> /f ALL'
}

if ($winre.lu) {
    if (-not $winre.active) {
        Add-Constat 'ATTENTION' 'WRE-001' 'WinRE est désactivé (pas d''environnement de récupération au démarrage).' 'reagentc /enable après les modifications.'
    } elseif ($winre.offset) {
        $cible = $partitions | Where-Object { $_.offset -eq $winre.offset }
        if (-not $cible) {
            Add-Constat 'BLOQUANT' 'WRE-002' "WinRE pointe vers une partition qui n'existe plus (offset $($winre.offset))." 'reagentc /disable puis /enable pour le réenregistrer.'
        } else {
            Add-Constat 'OK' 'WRE-003' "WinRE actif, sur la partition n°$($cible.numero) ($($cible.role))." `
                'Si cette partition est déplacée : reagentc /disable avant, /enable après (sinon WinRE est perdu).'
        }
    }
} else {
    Add-Constat 'ATTENTION' 'WRE-000' 'Configuration WinRE non lue.' 'Relancer en administrateur.'
}

if (-not $admin) { Add-Constat 'ATTENTION' 'ADM-001' 'Analyse partielle (pas en administrateur).' 'Relancer PowerShell en administrateur.' }

# --- Affichage -------------------------------------------------------------------------------------
$couleurs = @{ OK = 'Green'; INFO = 'Gray'; ATTENTION = 'Yellow'; BLOQUANT = 'Red'; WINPE = 'Magenta' }
Write-Host ''
Write-Host ("  Disque {0} : {1}  |  {2}  |  {3}  |  firmware {4}" -f $disk.Number, $disk.FriendlyName, $disk.PartitionStyle, (Format-Taille $disk.Size), $firmware) -ForegroundColor Cyan
Write-Host ''
Write-Host ('  {0,-3} {1,-14} {2,-4} {3,12} {4,12} {5,-6} {6}' -f 'N°', 'Rôle', 'Let.', 'Début', 'Taille', 'FS', 'Libre FS')
foreach ($s in $segments) {
    if ($s.type -eq 'libre') {
        Write-Host ('  {0,-3} {1,-14} {2,-4} {3,12} {4,12}' -f '-', '(non alloué)', '', (Format-Taille $s.offset), (Format-Taille $s.taille)) -ForegroundColor DarkGray
    } else {
        $p = $partitions | Where-Object numero -eq $s.numero
        $lib = if ($null -ne $p.libre_fs) { Format-Taille $p.libre_fs } else { '' }
        Write-Host ('  {0,-3} {1,-14} {2,-4} {3,12} {4,12} {5,-6} {6}' -f $p.numero, $p.role, $p.lettre, (Format-Taille $p.offset), (Format-Taille $p.taille), $p.fs, $lib)
    }
}
Write-Host ''
foreach ($c in $constats) {
    Write-Host ("  [{0}] {1} {2}" -f $c.niveau, $c.code, $c.texte) -ForegroundColor $couleurs[$c.niveau]
    if ($c.action) { Write-Host ("           -> {0}" -f $c.action) -ForegroundColor DarkGray }
}

# --- Rapport JSON ------------------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $DossierRapport | Out-Null
$rapport = [ordered]@{
    version_schema = 1
    date           = (Get-Date).ToString('s')
    admin          = $admin
    firmware       = $firmware
    disque         = [ordered]@{ numero = $disk.Number; modele = $disk.FriendlyName; style = "$($disk.PartitionStyle)"; taille = [int64]$disk.Size; bus = "$($disk.BusType)"; guid = $disk.Guid; signature = $disk.Signature }
    partitions     = $partitions
    segments       = $segments
    bitlocker      = $bitlocker
    winre          = $winre
    bcd            = [ordered]@{ bootmgr = $bcdMgr; os = $bcdOs }
    demarrage      = $demarrage
    constats       = $constats
}
$fichier = Join-Path $DossierRapport ("analyse_disque{0}_{1}.json" -f $disk.Number, (Get-Date -Format 'yyyyMMdd_HHmmss'))
$rapport | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fichier -Encoding UTF8
Write-Host ''
Write-Host "  Rapport : $fichier" -ForegroundColor DarkGray
