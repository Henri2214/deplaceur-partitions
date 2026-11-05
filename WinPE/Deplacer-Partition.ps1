#Requires -Version 5.1
<#
.SYNOPSIS
    Déplace une partition (y compris C:) sur son disque, hors ligne, avec reprise après coupure de courant.
.DESCRIPTION
    À lancer depuis WinPE (clé créée par Creer-CleWinPE.ps1) : la partition Windows ne peut pas être verrouillée
    pendant que Windows tourne. Sous Windows normal, seules les partitions de données non utilisées sont acceptées.

    Déroulé (chaque phase est inscrite dans le journal, sur un support qui n'est PAS le disque modifié) :
      1. copie      blocs copiés dans le bon sens, bloc <= décalage (reprise toujours possible)
      2. boot       champ « hidden sectors » du secteur de démarrage NTFS/FAT32 (+ copie de secours)
      3. table      nouvelle position écrite dans la table de partitions (GUID et attributs conservés)
      4. demarrage  MountedDevices (MBR), ReAgent.xml, bcdboot, lettre de lecteur
    SIMULATION PAR DÉFAUT : ajoutez -Executer pour appliquer.
.EXAMPLE
    .\Deplacer-Partition.ps1 -Disque 0 -Partition 3 -Direction Gauche -DossierJournal E:\Journal
    .\Deplacer-Partition.ps1 -Reprendre E:\Journal\deplacement.json -Executer
#>
[CmdletBinding(DefaultParameterSetName = 'Nouveau')]
param(
    [Parameter(ParameterSetName = 'Nouveau', Mandatory)][int]$Disque,
    [Parameter(ParameterSetName = 'Nouveau', Mandatory)][int]$Partition,
    [Parameter(ParameterSetName = 'Nouveau')][ValidateSet('Gauche', 'Droite')][string]$Direction = 'Gauche',
    [Parameter(ParameterSetName = 'Nouveau')][int64]$NouvelOffsetMo = -1,
    [Parameter(ParameterSetName = 'Nouveau', Mandatory)][string]$DossierJournal,
    [Parameter(ParameterSetName = 'Reprise', Mandatory)][string]$Reprendre,
    [switch]$Executer
)

$ErrorActionPreference = 'Stop'
$Racine = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($m in 'Commun', 'DisqueBrut', 'Copie', 'Registre') { . (Join-Path $Racine "lib\$m.ps1") }
$script:Executer = [bool]$Executer
$MiB = [int64]1MB

if (-not (Test-Admin)) { throw 'Droits administrateur requis.' }

function Get-BornesUtiles([int]$Num, [int64]$TailleDisque) {
    $b = Read-LayoutBrut $Num
    if ([BitConverter]::ToUInt32($b, 0) -eq 1) {
        $debut = [BitConverter]::ToInt64($b, 24); $long = [BitConverter]::ToInt64($b, 32)
        return [pscustomobject]@{ debut = $debut; fin = $debut + $long }
    }
    return [pscustomobject]@{ debut = [int64]512; fin = $TailleDisque }
}

function Test-DossierJournal([string]$Dossier, [int]$Num) {
    New-Item -ItemType Directory -Force -Path $Dossier | Out-Null
    $l = (Resolve-Path -LiteralPath $Dossier).Path.Substring(0, 1)
    if ((Test-WinPE) -and $l -eq 'X') { throw 'X: est un disque en mémoire (effacé au redémarrage) : choisissez la clé USB ou un autre disque pour le journal.' }
    $pj = Get-Partition -DriveLetter $l -ErrorAction SilentlyContinue
    if ($pj -and $pj.DiskNumber -eq $Num) { throw 'Le journal ne doit pas être sur le disque modifié.' }
    $t = Join-Path $Dossier 'test_ecriture.tmp'
    Set-Content -LiteralPath $t -Value 'ok'; Remove-Item -LiteralPath $t
}

function Get-IdentiteDisque($Disk) { return "$($Disk.Guid)|$($Disk.Signature)|$($Disk.SerialNumber)|$($Disk.Size)" }

# ======================================================================== préparation
if ($PSCmdlet.ParameterSetName -eq 'Reprise') {
    $cheminJournal = (Resolve-Path -LiteralPath $Reprendre).Path
    $etat = Read-JournalDeplacement $cheminJournal
    $disk = Get-Disk -Number $etat.disque
    if ((Get-IdentiteDisque $disk) -ne $etat.identite_disque) { throw "Le disque n°$($etat.disque) n'est pas celui du journal (ordre des disques changé ?). Vérifiez avec Get-Disk." }
    $script:FichierLog = Join-Path (Split-Path -Parent $cheminJournal) 'journal.log'
    Write-Log ("Reprise : phase « {0} », bloc {1}" -f $etat.phase, $etat.etape_faite) 'ETAPE'
} else {
    $disk = Get-Disk -Number $Disque
    $p = Get-Partition -DiskNumber $Disque -PartitionNumber $Partition
    $secteur = [int]$disk.LogicalSectorSize
    $source = [int64]$p.Offset; $taille = [int64]$p.Size
    $bornes = Get-BornesUtiles $Disque ([int64]$disk.Size)
    $autres = @(Get-Partition -DiskNumber $Disque | Where-Object { $_.PartitionNumber -ne $Partition } | Sort-Object Offset)
    $avant = $autres | Where-Object { $_.Offset -lt $source } | Select-Object -Last 1
    $apres = $autres | Where-Object { $_.Offset -gt $source } | Select-Object -First 1

    if ($NouvelOffsetMo -ge 0) { $dest = $NouvelOffsetMo * $MiB }
    elseif ($Direction -eq 'Gauche') {
        $min = if ($avant) { [int64]$avant.Offset + [int64]$avant.Size } else { $bornes.debut }
        $dest = [int64]([math]::Ceiling($min / $MiB) * $MiB)
    } else {
        $max = if ($apres) { [int64]$apres.Offset } else { $bornes.fin }
        $dest = [int64]([math]::Floor(($max - $taille) / $MiB) * $MiB)
    }
    if ($dest -eq $source) { Write-Log 'La partition est déjà à cette position : rien à faire.' 'OK'; return }
    if ($dest % $secteur -ne 0) { throw 'Position cible non alignée sur un secteur.' }
    if ($dest -lt $bornes.debut -or $dest + $taille -gt $bornes.fin) { throw 'Position cible hors de la zone utilisable du disque.' }
    foreach ($a in $autres) {
        if ($dest -lt ([int64]$a.Offset + [int64]$a.Size) -and ($dest + $taille) -gt [int64]$a.Offset) { throw "La position cible chevauche la partition n°$($a.PartitionNumber)." }
    }
    $lettre = Get-LettrePartition $p
    if (-not (Test-WinPE) -and $lettre -and "$lettre" -eq $env:SystemDrive) { throw 'Impossible de déplacer la partition de la Windows en cours : démarrez sur la clé WinPE.' }
    $estWindows = [bool]($lettre -and (Test-Path -LiteralPath "$lettre\Windows\System32\config\SYSTEM"))
    $bloc = Get-TailleBloc ($dest - $source) $secteur

    Write-Log ("Disque {0} ({1}, {2}) - partition n°{3} {4} {5}" -f $Disque, $disk.FriendlyName, $disk.PartitionStyle, $Partition, $lettre, (Format-Taille $taille))
    Write-Log ("Position : {0} -> {1} (décalage {2}, blocs de {3})" -f (Format-Taille $source), (Format-Taille $dest), (Format-Taille ($dest - $source)), (Format-Taille $bloc))
    Write-Log ("Durée estimée : environ {0:N0} min à 150 Mo/s" -f ($taille / 150MB / 60))
    if ($estWindows) { Write-Log 'Partition Windows : le démarrage sera reconstruit et vérifié à la fin.' 'INFO' }

    Test-DossierJournal $DossierJournal $Disque
    if (-not $script:Executer) {
        Write-Log 'Simulation : rien n''a été modifié. Ajoutez -Executer pour lancer le déplacement.' 'SIMULATION'
        return
    }
    if (-not (Confirm-Operation "Déplacer la partition n°$Partition du disque $Disque ($(Format-Taille $taille)) ? NE PAS ÉTEINDRE pendant l'opération (une coupure reste rattrapable via la reprise).")) { Write-Log 'Annulé.' 'ATTENTION'; return }

    $script:FichierLog = Join-Path $DossierJournal 'journal.log'
    Save-EtatDisque -Disque $Disque -Dossier $DossierJournal -RacineWindows $(if ($estWindows) { "$lettre\Windows" } else { "$env:SystemRoot" })
    $id = if ($disk.PartitionStyle -eq 'GPT') { "$($p.Guid)" } else { $null }
    $etat = [pscustomobject][ordered]@{
        version = 1; disque = $Disque; identite_disque = (Get-IdentiteDisque $disk); style = "$($disk.PartitionStyle)"
        signature = [uint32]$(if ($disk.Signature) { $disk.Signature } else { 0 }); secteur = $secteur
        partition = $Partition; partition_id = $id; lettre = "$lettre"; est_windows = $estWindows
        source = $source; destination = $dest; taille = $taille; bloc = $bloc
        phase = 'copie'; etape_faite = -1; maj = ''
    }
    $cheminJournal = Join-Path $DossierJournal 'deplacement.json'
    Save-JournalDeplacement $cheminJournal $etat
    Write-Log "Journal de reprise : $cheminJournal" 'OK'
}

# ======================================================================== exécution
$script:Executer = $true
$hVol = $null; $hDisk = $null
try {
    if ($etat.phase -in 'copie', 'boot', 'table') {
        # Sous WinPE : pas de remontage automatique en cours de route (réglage perdu au redémarrage de WinPE).
        if (Test-WinPE) { Invoke-Externe -Exe 'mountvol.exe' -Arguments @('/N') -Tolerant | Out-Null }
        $pSrc = Get-Partition -DiskNumber $etat.disque | Where-Object { [int64]$_.Offset -eq [int64]$etat.source } | Select-Object -First 1
        if ($pSrc) {
            $l = Get-LettrePartition $pSrc
            $vol = $null; try { $vol = $pSrc | Get-Volume -ErrorAction Stop } catch { }
            if ($vol -and $vol.Path) { $hVol = Lock-Volume $vol.Path; Write-Log 'Volume verrouillé et démonté.' 'OK' }
            if ($l) { Remove-PartitionAccessPath -DiskNumber $etat.disque -PartitionNumber $pSrc.PartitionNumber -AccessPath "$l\" -ErrorAction SilentlyContinue }
        }
        if ($etat.phase -ne 'table') { $hDisk = [DP.Brut]::Ouvrir("\\.\PhysicalDrive$($etat.disque)", $true) }
    }

    if ($etat.phase -eq 'copie') {
        Write-Log 'Phase 1/4 : copie des données' 'ETAPE'
        $n = Invoke-CopieBlocs -Source $etat.source -Destination $etat.destination -Taille $etat.taille -Bloc $etat.bloc -Etat $etat `
            -Lire { param($o, $len) [DP.Brut]::Lire($hDisk, $o, $len) } `
            -Ecrire { param($o, $d) [DP.Brut]::Ecrire($hDisk, $o, $d) } `
            -Vider { [DP.Brut]::Vider($hDisk) } `
            -Sauver { param($e) Save-JournalDeplacement $cheminJournal $e }
        Write-Log "$n blocs copiés." 'OK'
        $etat.phase = 'boot'; Save-JournalDeplacement $cheminJournal $etat
    }

    if ($etat.phase -eq 'boot') {
        Write-Log 'Phase 2/4 : secteur de démarrage' 'ETAPE'
        $s0 = [DP.Brut]::Lire($hDisk, $etat.destination, $etat.secteur)
        $maj = Update-SecteurBoot $s0 $etat.destination
        if ($maj) {
            $posSecours = Get-PositionSecoursBoot $s0
            [DP.Brut]::Ecrire($hDisk, $etat.destination, $maj)
            if ($null -ne $posSecours -and $posSecours -lt $etat.taille) {
                $s1 = [DP.Brut]::Lire($hDisk, $etat.destination + $posSecours, $etat.secteur)
                $maj1 = Update-SecteurBoot $s1 $etat.destination
                if ($maj1) { [DP.Brut]::Ecrire($hDisk, $etat.destination + $posSecours, $maj1) }
            }
            [DP.Brut]::Vider($hDisk)
            Write-Log 'Champ « hidden sectors » mis à jour (secteur principal et copie de secours).' 'OK'
        } else { Write-Log 'Système de fichiers sans champ à corriger (BitLocker, ReFS ou autre) : rien à faire.' 'INFO' }
        $etat.phase = 'table'; Save-JournalDeplacement $cheminJournal $etat
    }

    if ($hDisk) { $hDisk.Dispose(); $hDisk = $null }

    if ($etat.phase -eq 'table') {
        Write-Log 'Phase 3/4 : table de partitions' 'ETAPE'
        $brut = Read-LayoutBrut $etat.disque
        $entrees = (ConvertFrom-LayoutBrut $brut).entrees
        $e = if ($etat.partition_id) { $entrees | Where-Object { $_.id -eq $etat.partition_id } } else { $entrees | Where-Object { $_.offset -eq $etat.source -and $_.taille -gt 0 } }
        if (-not $e) {
            $deja = $entrees | Where-Object { $_.offset -eq $etat.destination -and $_.taille -eq $etat.taille }
            if (-not $deja) { throw 'Entrée de partition introuvable dans la table.' }
            Write-Log 'Table déjà à jour (reprise).' 'INFO'
        } elseif ($e.offset -ne $etat.destination) {
            $nouveau = Set-OffsetLayout -B $brut -Numero $e.numero -Nouvel $etat.destination -TailleSecteur $etat.secteur
            Write-LayoutBrut $etat.disque $nouveau
            $verif = (ConvertFrom-LayoutBrut (Read-LayoutBrut $etat.disque)).entrees | Where-Object { $_.offset -eq $etat.destination -and $_.taille -eq $etat.taille }
            if (-not $verif) { throw 'La table relue ne contient pas la nouvelle position.' }
            Write-Log 'Table de partitions mise à jour (GUID et attributs conservés).' 'OK'
        }
        if ($hVol) { $hVol.Dispose(); $hVol = $null }
        $etat.phase = 'demarrage'; Save-JournalDeplacement $cheminJournal $etat
    }

    if ($etat.phase -eq 'demarrage') {
        Write-Log 'Phase 4/4 : démarrage' 'ETAPE'
        if ($hVol) { $hVol.Dispose(); $hVol = $null }
        if (Test-WinPE) { Invoke-Externe -Exe 'mountvol.exe' -Arguments @('/E') -Tolerant | Out-Null }
        Update-Disk -Number $etat.disque
        $pNew = Get-Partition -DiskNumber $etat.disque | Where-Object { [int64]$_.Offset -eq [int64]$etat.destination } | Select-Object -First 1
        if (-not $pNew) { throw 'Partition introuvable à sa nouvelle position.' }
        if ($etat.lettre -and -not (Get-LettrePartition $pNew)) {
            try { Add-PartitionAccessPath -DiskNumber $etat.disque -PartitionNumber $pNew.PartitionNumber -AccessPath "$($etat.lettre)\" }
            catch { Add-PartitionAccessPath -DiskNumber $etat.disque -PartitionNumber $pNew.PartitionNumber -AssignDriveLetter }
            $pNew = Get-Partition -DiskNumber $etat.disque -PartitionNumber $pNew.PartitionNumber
        }

        $installations = @(Find-PartitionsWindows)
        foreach ($w in $installations) {
            $rw = "$(Get-LettrePartition $w)\Windows"
            if ($etat.style -eq 'MBR') {
                $n = Update-MountedDevicesDeplacement -RacineWindows $rw -Signature $etat.signature -AncienOffset $etat.source -NouvelOffset $etat.destination
                if ($n -eq 0) { Write-Log "MountedDevices de $rw : aucune entrée à corriger." 'INFO' }
            }
            # ReAgent.xml : position de WinRE si c'est la partition de récupération qui a bougé.
            $xmlF = Join-Path $rw 'System32\Recovery\ReAgent.xml'
            if (Test-Path -LiteralPath $xmlF) {
                [xml]$x = Get-Content -LiteralPath $xmlF -Raw
                $loc = $x.SelectSingleNode('//WinreLocation')
                if ($loc -and $loc.GetAttribute('offset') -eq "$($etat.source)") {
                    Copy-Item -LiteralPath $xmlF -Destination (Join-Path (Split-Path -Parent $cheminJournal) 'ReAgent.avant.xml') -Force
                    $loc.SetAttribute('offset', "$($etat.destination)")
                    $x.Save($xmlF)
                    Write-Log "ReAgent.xml de $rw : position de WinRE corrigée. Après redémarrage, lancez Operations.ps1 -Action ReparerWinRE pour confirmer." 'OK'
                }
            }
        }

        # Reconstruction du démarrage : obligatoire en MBR (le BCD repère Windows par position), recommandée en GPT.
        $disk = Get-Disk -Number $etat.disque
        $sysType = if ($etat.style -eq 'GPT') { 'UEFI' } else { 'BIOS' }
        $sysPart = if ($etat.style -eq 'GPT') { Get-Partition -DiskNumber $etat.disque | Where-Object GptType -eq $GPT.EFI | Select-Object -First 1 }
                   else { Get-Partition -DiskNumber $etat.disque | Where-Object IsActive | Select-Object -First 1 }
        $winDisque = @($installations | Where-Object DiskNumber -eq $etat.disque)
        if ($sysPart -and $winDisque.Count -ge 1) {
            $m = Mount-PartitionTemporaire $sysPart
            try {
                foreach ($w in $winDisque) {
                    $rw = "$(Get-LettrePartition $w)\Windows"
                    Invoke-Externe -Exe 'bcdboot.exe' -Arguments @($rw, '/s', $m.lettre, '/f', $sysType) | Out-Null
                    Write-Log "Démarrage reconstruit pour $rw (bcdboot, $sysType)." 'OK'
                }
                $f = if ($sysType -eq 'UEFI') { 'EFI\Microsoft\Boot\bootmgfw.efi' } else { 'bootmgr' }
                if (-not (Test-Path -LiteralPath (Join-Path "$($m.lettre)\" $f))) { throw "Fichier de démarrage absent après bcdboot : $f" }
                Write-Log "Fichier de démarrage présent : $f" 'OK'
            } finally { Dismount-PartitionTemporaire $m }
        } elseif ($winDisque.Count -eq 0) { Write-Log 'Aucune Windows sur ce disque : pas de reconstruction du démarrage.' 'INFO' }
        else { Write-Log 'Partition système (EFI/active) introuvable : démarrage non reconstruit.' 'ERREUR' }

        $etat.phase = 'termine'; Save-JournalDeplacement $cheminJournal $etat
        $fin = Join-Path (Split-Path -Parent $cheminJournal) ("deplacement_termine_{0}.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Move-Item -LiteralPath $cheminJournal -Destination $fin
        Write-Log 'Déplacement terminé. Retirez la clé et redémarrez.' 'OK'
    }
} catch {
    Write-Log "INTERRUPTION : $($_.Exception.Message)" 'ERREUR'
    Write-Log "NE DÉMARREZ PAS WINDOWS. Corrigez la cause puis relancez : Deplacer-Partition.ps1 -Reprendre `"$cheminJournal`" -Executer" 'ERREUR'
    throw
} finally {
    if ($hDisk) { $hDisk.Dispose() }
    if ($hVol) { $hVol.Dispose() }
}
