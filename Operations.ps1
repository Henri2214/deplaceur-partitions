#Requires -Version 5.1
<#
.SYNOPSIS
    Opérations sur les partitions réalisables pendant que Windows tourne, sans risque pour le démarrage.
.DESCRIPTION
    SIMULATION PAR DÉFAUT : sans -Executer, rien n'est modifié ; le plan est seulement affiché.
    Avant chaque opération : sauvegarde (table de partitions brute, BCD, ReAgent.xml, image WinRE) ;
    après : vérification complète de la chaîne de démarrage.

    Actions :
      Verifier          contrôle la chaîne de démarrage (EFI, BCD, WinRE, BitLocker)
      Agrandir          agrandit une partition dans l'espace libre qui la suit (-TailleGo, 0 = maximum)
      Reduire           réduit une partition (-TailleGo = nouvelle taille)
      DeplacerRecovery  déplace la partition de récupération en fin de disque et agrandit C: (procédure Microsoft KB5028997)
      ReparerDemarrage  recrée les fichiers de démarrage (bcdboot), BitLocker suspendu au préalable
      ReparerWinRE      réenregistre l'environnement de récupération (reagentc)
      RestaurerBcd      réimporte une sauvegarde du BCD (-FichierBcd)
.EXAMPLE
    .\Operations.ps1 -Action DeplacerRecovery               # affiche le plan
    .\Operations.ps1 -Action DeplacerRecovery -Executer     # l'exécute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Verifier', 'Agrandir', 'Reduire', 'DeplacerRecovery', 'ReparerDemarrage', 'ReparerWinRE', 'RestaurerBcd')]
    [string]$Action,
    [string]$Lettre = $env:SystemDrive,
    [double]$TailleGo = 0,
    [double]$TailleRecoveryMo = 0,
    [string]$FichierBcd = '',
    [string]$DossierSauvegardes = '',
    [switch]$Executer
)

$ErrorActionPreference = 'Stop'
$Racine = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Racine 'lib\Commun.ps1')
. (Join-Path $Racine 'lib\DisqueBrut.ps1')
$script:Executer = [bool]$Executer
if (-not $DossierSauvegardes) { $DossierSauvegardes = Join-Path $Racine 'sauvegardes' }
$Lettre = $Lettre.TrimEnd(':', '\').ToUpper()
$MiB = [int64]1MB

if (Test-WinPE) { throw 'Sous WinPE, utilisez WinPE\Menu.ps1 (ces opérations visent la Windows en cours).' }
if ($Action -ne 'Verifier' -and $script:Executer -and -not (Test-Admin)) { throw 'Droits administrateur requis : relancez PowerShell « en tant qu''administrateur ».' }

Write-Host ''
Write-Host ("  Déplaceur de partitions - {0}{1}" -f $Action, $(if ($script:Executer) { '' } else { '  (SIMULATION : ajoutez -Executer pour appliquer)' })) -ForegroundColor Cyan
Write-Host ''

function Suspend-BitLockerSiActif([string]$L) {
    $bl = Get-BitLocker $L
    if ($bl.lu -and $bl.protection -eq 'ACTIVE') {
        Invoke-Etape "Suspension de BitLocker sur $($L): jusqu'au prochain redémarrage (évite la demande de clé de récupération)" {
            try { Suspend-BitLocker -MountPoint "$($L):" -RebootCount 1 | Out-Null }
            catch { Invoke-Externe -Exe 'manage-bde.exe' -Arguments @('-protectors', '-disable', "$($L):", '-RebootCount', '1') | Out-Null }
        } | Out-Null
    } elseif (-not $bl.lu) {
        Write-Log "État BitLocker de $($L): non lu : si la clé de récupération est demandée au redémarrage, elle est dans votre compte Microsoft." 'ATTENTION'
    }
}

function Show-FinOperation {
    Write-Host ''
    if (-not $script:Executer) { Write-Log 'Simulation terminée : aucune modification. Relancez avec -Executer pour appliquer.' 'SIMULATION'; return }
    Write-Log 'Vérification de la chaîne de démarrage après l''opération :' 'ETAPE'
    $c = Test-Demarrage
    Show-Controles $c
    if ($c | Where-Object { $_.ok -eq $false }) {
        Write-Log 'Un contrôle a échoué : NE REDÉMARREZ PAS avant d''avoir lancé -Action ReparerDemarrage (ou ReparerWinRE).' 'ERREUR'
    } else { Write-Log 'Démarrage vérifié : vous pouvez redémarrer.' 'OK' }
    if ($script:FichierLog) { Write-Log "Journal et sauvegardes : $(Split-Path -Parent $script:FichierLog)" 'INFO' }
}

function Get-FinUtile($Disk) {
    $fin = if ($Disk.PartitionStyle -eq 'GPT') { [int64]$Disk.Size - $MiB } else { [int64]$Disk.Size }
    return [int64]([math]::Floor($fin / $MiB) * $MiB)
}

switch ($Action) {

    'Verifier' {
        if (-not (Test-Admin)) { Write-Log 'Pas en administrateur : contrôles partiels.' 'ATTENTION' }
        Show-Controles (Test-Demarrage)
    }

    { $_ -in 'Agrandir', 'Reduire' } {
        $p = Get-Partition -DriveLetter $Lettre
        try { $s = Get-PartitionSupportedSize -DriveLetter $Lettre }
        catch { throw 'Windows ne calcule les tailles possibles qu''en administrateur : relancez PowerShell « en tant qu''administrateur » (la simulation reste sans risque).' }
        $actuelle = [int64]$p.Size
        if ($Action -eq 'Agrandir') {
            $cible = if ($TailleGo -gt 0) { [int64]($TailleGo * 1GB) } else { [int64]$s.SizeMax }
            if ($s.SizeMax - $actuelle -lt $MiB) {
                Write-Log "Aucun espace libre juste après $($Lettre):. Lancez Analyse-Partitions.ps1 : si la partition de récupération bloque, utilisez -Action DeplacerRecovery." 'ERREUR'
                return
            }
            if ($cible -gt $s.SizeMax) { throw "Taille demandée supérieure au maximum possible ($(Format-Taille $s.SizeMax))." }
            if ($cible -le $actuelle) { throw 'La taille demandée n''agrandit pas la partition.' }
        } else {
            if ($TailleGo -le 0) { throw 'Précisez -TailleGo (nouvelle taille).' }
            $cible = [int64]($TailleGo * 1GB)
            if ($cible -lt $s.SizeMin) {
                throw ("Minimum possible : {0}. Les fichiers non déplaçables (pagefile, hiberfil, points de restauration, MFT) bloquent en dessous : " -f (Format-Taille $s.SizeMin)) +
                    'désactivez temporairement l''hibernation (powercfg /h off) et le fichier d''échange, puis réessayez.'
            }
            if ($cible -ge $actuelle) { throw 'La taille demandée ne réduit pas la partition.' }
        }
        if ($cible -ne $s.SizeMax) { $cible = [int64]([math]::Floor($cible / $MiB) * $MiB) }
        Write-Log ("{0}: {1} -> {2}" -f $Lettre, (Format-Taille $actuelle), (Format-Taille $cible))
        if (-not (Confirm-Operation "Redimensionner $($Lettre): à $(Format-Taille $cible) ?")) { Write-Log 'Annulé.' 'ATTENTION'; return }
        if ($script:Executer) { $d = New-DossierSauvegarde $DossierSauvegardes $Action; Save-EtatDisque -Disque $p.DiskNumber -Dossier $d }
        Invoke-Etape "Redimensionnement de $($Lettre): à $(Format-Taille $cible)" { Resize-Partition -DriveLetter $Lettre -Size $cible } | Out-Null
        Show-FinOperation
    }

    'DeplacerRecovery' {
        $win = Get-Partition -DriveLetter $Lettre
        $disk = Get-Disk -Number $win.DiskNumber
        $parts = @(Get-Partition -DiskNumber $disk.Number | Sort-Object Offset)
        $wre = Get-WinRE
        $finWin = [int64]$win.Offset + [int64]$win.Size

        # Partition de récupération : celle de WinRE si elle suit C:, sinon la première de type Recovery après C:.
        $rec = $parts | Where-Object { $wre.offset -and [int64]$_.Offset -eq $wre.offset -and $_.Offset -ge $finWin } | Select-Object -First 1
        if (-not $rec) {
            $rec = $parts | Where-Object { $_.Offset -ge $finWin -and ($_.GptType -eq $GPT.Recovery -or $_.MbrType -eq 0x27) } | Select-Object -First 1
        }
        if (-not $rec) { throw "Aucune partition de récupération après $($Lettre): sur le disque $($disk.Number)." }
        $entre = $parts | Where-Object { $_.Offset -ge $finWin -and $_.Offset -lt $rec.Offset }
        if ($entre) { throw "Une autre partition se trouve entre $($Lettre): et la partition de récupération : cas non pris en charge en ligne." }

        $suivante = $parts | Where-Object { $_.Offset -gt $rec.Offset } | Select-Object -First 1
        $limite = if ($suivante) { [int64]$suivante.Offset } else { Get-FinUtile $disk }
        $tailleRec = [int64]([math]::Ceiling([math]::Max([double]$rec.Size, $TailleRecoveryMo * 1MB) / $MiB) * $MiB)

        $calcul = {
            param([int64]$tRec)
            $offRec = [int64]([math]::Floor(($limite - $tRec) / $MiB) * $MiB)
            $maxC = $offRec - [int64]$win.Offset
            $tC = if ($TailleGo -gt 0) { [int64]([math]::Floor($TailleGo * 1GB / $MiB) * $MiB) } else { $maxC }
            if ($tC -gt $maxC) { throw "Taille demandée pour $($Lettre): trop grande (maximum $(Format-Taille $maxC))." }
            if ($tC -lt [int64]$win.Size) { throw "La taille demandée ($(Format-Taille $tC)) est inférieure à la taille actuelle de $($Lettre): : utilisez -Action Reduire." }
            [pscustomobject]@{ offRec = $offRec; tailleC = $tC; tailleRec = $tRec }
        }
        $plan = & $calcul $tailleRec
        $gain = $plan.tailleC - [int64]$win.Size
        Write-Log ("Partition de récupération n°{0} : {1} à {2} -> déplacée à {3} ({4})" -f $rec.PartitionNumber, (Format-Taille $rec.Size), (Format-Taille $rec.Offset), (Format-Taille $plan.offRec), (Format-Taille $plan.tailleRec))
        Write-Log ("{0}: {1} -> {2} (gain {3})" -f $Lettre, (Format-Taille $win.Size), (Format-Taille $plan.tailleC), (Format-Taille $gain))
        if ($gain -lt 1GB -and $TailleGo -le 0) {
            Write-Log "Gain inférieur à 1 Go : opération inutile. Libérez d'abord de l'espace derrière la partition de récupération (réduction ou suppression d'une autre partition, disque plus grand)." 'ATTENTION'
            return
        }
        if (-not (Confirm-Operation "Déplacer la partition de récupération et agrandir $($Lettre): de $(Format-Taille $gain) ?")) { Write-Log 'Annulé.' 'ATTENTION'; return }

        $dossier = $null
        if ($script:Executer) { $dossier = New-DossierSauvegarde $DossierSauvegardes 'DeplacerRecovery'; Save-EtatDisque -Disque $disk.Number -Dossier $dossier }
        Suspend-BitLockerSiActif $Lettre

        $wimLocal = Join-Path $env:SystemRoot 'System32\Recovery\Winre.wim'
        Invoke-Etape 'Désactivation de WinRE (reagentc /disable : l''image WinRE est rapatriée sur C:)' {
            if ($wre.active) { Invoke-Externe -Exe 'reagentc.exe' -Arguments @('/disable') | Out-Null }
            if (-not (Test-Path -LiteralPath $wimLocal -PathType Leaf)) {
                Invoke-Externe -Exe 'reagentc.exe' -Arguments @('/enable') -Tolerant | Out-Null
                throw "Winre.wim introuvable dans $(Split-Path $wimLocal) après désactivation : arrêt AVANT toute modification de partition."
            }
            Copy-Item -LiteralPath $wimLocal -Destination (Join-Path $dossier 'Winre.wim')
            Write-Log "Image WinRE sauvegardée ($(Format-Taille (Get-Item -LiteralPath $wimLocal -Force).Length))." 'OK'
            $besoin = [int64]([math]::Ceiling(((Get-Item -LiteralPath $wimLocal -Force).Length + 320MB) / $MiB) * $MiB)
            if ($besoin -gt $plan.tailleRec) {
                Write-Log "Partition de récupération agrandie à $(Format-Taille $besoin) pour contenir l'image WinRE et ses mises à jour." 'INFO'
                $script:PlanRecovery = & $calcul $besoin
            }
        } | Out-Null
        if ($script:Executer -and (Get-Variable -Name PlanRecovery -Scope Script -ErrorAction SilentlyContinue)) { $plan = $script:PlanRecovery }

        try {
            Invoke-Etape "Suppression de l'ancienne partition de récupération n°$($rec.PartitionNumber)" {
                Remove-Partition -DiskNumber $disk.Number -PartitionNumber $rec.PartitionNumber -Confirm:$false
            } | Out-Null
            Invoke-Etape "Agrandissement de $($Lettre): à $(Format-Taille $plan.tailleC)" {
                Resize-Partition -DriveLetter $Lettre -Size $plan.tailleC
            } | Out-Null
            Invoke-Etape "Création de la partition de récupération en fin de disque ($(Format-Taille $plan.tailleRec))" {
                $l = @("select disk $($disk.Number)", ("create partition primary offset={0} size={1}" -f ($plan.offRec / 1KB), ($plan.tailleRec / $MiB)),
                       'format quick fs=ntfs label="Windows RE tools"')
                if ($disk.PartitionStyle -eq 'GPT') { $l += "set id=`"$($GPT.Recovery.Trim('{}'))`"", "gpt attributes=$script:AttributsRecovery" }
                else { $l += 'set id=27' }
                Invoke-Diskpart $l | Out-Null
                $nouvelle = Get-Partition -DiskNumber $disk.Number | Where-Object { [int64]$_.Offset -eq $plan.offRec }
                if (-not $nouvelle) { throw 'Partition de récupération introuvable après création.' }
                Write-Log "Partition de récupération créée (n°$($nouvelle.PartitionNumber))." 'OK'
            } | Out-Null
            Invoke-Etape 'Réactivation de WinRE (reagentc /enable : l''image est replacée dans la nouvelle partition)' {
                Invoke-Externe -Exe 'reagentc.exe' -Arguments @('/enable') | Out-Null
                $apres = Get-WinRE
                if (-not $apres.active) { throw 'WinRE ne s''est pas réactivé.' }
                if ($apres.offset -ne $plan.offRec) { Write-Log "WinRE réactivé, mais sur l'offset $($apres.offset) (attendu $($plan.offRec))." 'ATTENTION' }
                else { Write-Log 'WinRE actif dans la nouvelle partition de récupération.' 'OK' }
            } | Out-Null
        } catch {
            Write-Log "ÉCHEC : $($_.Exception.Message)" 'ERREUR'
            Write-Log 'Repli : réactivation de WinRE sur C: (Windows et son démarrage ne sont pas touchés par cette opération).' 'ATTENTION'
            Invoke-Externe -Exe 'reagentc.exe' -Arguments @('/enable') -Tolerant | Out-Null
            Write-Log "Image WinRE de secours : $dossier\Winre.wim" 'INFO'
        }
        Show-FinOperation
    }

    'ReparerDemarrage' {
        if (-not (Confirm-Operation 'Recréer les fichiers de démarrage de la Windows en cours (bcdboot) ?')) { Write-Log 'Annulé.' 'ATTENTION'; return }
        if ($script:Executer) {
            $d = New-DossierSauvegarde $DossierSauvegardes 'ReparerDemarrage'
            Save-EtatDisque -Disque (Get-Partition -DriveLetter $Lettre).DiskNumber -Dossier $d
        }
        Suspend-BitLockerSiActif $Lettre
        Invoke-Etape "bcdboot $env:SystemRoot (fichiers de démarrage et entrée BCD recréés sur la partition système)" {
            Invoke-Externe -Exe 'bcdboot.exe' -Arguments @($env:SystemRoot, '/l', (Get-UICulture).Name) | Out-Null
        } | Out-Null
        Show-FinOperation
    }

    'ReparerWinRE' {
        if (-not (Confirm-Operation 'Réenregistrer WinRE (reagentc /disable puis /enable) ?')) { Write-Log 'Annulé.' 'ATTENTION'; return }
        Invoke-Etape 'reagentc /disable puis /enable' {
            Invoke-Externe -Exe 'reagentc.exe' -Arguments @('/disable') -Tolerant | Out-Null
            Invoke-Externe -Exe 'reagentc.exe' -Arguments @('/enable') | Out-Null
        } | Out-Null
        Show-FinOperation
    }

    'RestaurerBcd' {
        if (-not $FichierBcd -or -not (Test-Path -LiteralPath $FichierBcd)) { throw 'Précisez -FichierBcd (bcd.sauvegarde d''un dossier de sauvegardes).' }
        if (-not (Confirm-Operation "Réimporter le BCD depuis $FichierBcd ?")) { Write-Log 'Annulé.' 'ATTENTION'; return }
        Suspend-BitLockerSiActif $Lettre
        Invoke-Etape "bcdedit /import $FichierBcd" { Invoke-Externe -Exe 'bcdedit.exe' -Arguments @('/import', $FichierBcd) | Out-Null } | Out-Null
        Show-FinOperation
    }
}
