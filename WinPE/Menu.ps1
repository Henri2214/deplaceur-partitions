#Requires -Version 5.1
# Menu de la clé WinPE. Au démarrage : recherche d'un déplacement interrompu et reprise proposée en priorité.
$ErrorActionPreference = 'Continue'
$Ici = Split-Path -Parent $MyInvocation.MyCommand.Path
$Racine = Split-Path -Parent $Ici
. (Join-Path $Racine 'lib\Commun.ps1')

function Find-JournauxEnCours {
    Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne 'X' } | ForEach-Object {
        Get-ChildItem -LiteralPath "$($_.DriveLetter):\" -Filter 'deplacement.json' -Recurse -Depth 2 -ErrorAction SilentlyContinue
    }
}

function Show-Disques {
    foreach ($d in Get-Disk | Sort-Object Number) {
        Write-Host ("  Disque {0} : {1}  {2}  {3}" -f $d.Number, $d.FriendlyName, $d.PartitionStyle, (Format-Taille $d.Size)) -ForegroundColor Cyan
        foreach ($p in Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Sort-Object Offset) {
            $win = $(if ((Get-LettrePartition $p) -and (Test-Path "$(Get-LettrePartition $p)\Windows\System32\config\SYSTEM")) { 'Windows' } else { '' })
            Write-Host ("     n°{0,-2} {1,-3} {2,10} à {3,10}  {4} {5}" -f $p.PartitionNumber, (Get-LettrePartition $p), (Format-Taille $p.Size), (Format-Taille $p.Offset), $p.Type, $win)
        }
    }
}

function Read-Choix([string]$Question) { return (Read-Host "  $Question").Trim() }

$journaux = @(Find-JournauxEnCours)
if ($journaux.Count -gt 0) {
    Write-Host ''
    Write-Host '  !!! DÉPLACEMENT INTERROMPU DÉTECTÉ !!!' -ForegroundColor Red
    foreach ($j in $journaux) { Write-Host "  $($j.FullName)" -ForegroundColor Yellow }
    if ((Read-Choix 'Reprendre maintenant le premier ? (O/N)') -match '^[oO]') {
        & (Join-Path $Ici 'Deplacer-Partition.ps1') -Reprendre $journaux[0].FullName -Executer
    }
}

while ($true) {
    Write-Host ''
    Write-Host '  ===== Déplaceur de partitions (WinPE) =====' -ForegroundColor Cyan
    Write-Host '  1  Afficher les disques'
    Write-Host '  2  Analyser un disque'
    Write-Host '  3  Déplacer une partition'
    Write-Host '  4  Migrer Windows vers un autre disque'
    Write-Host '  5  Reprendre un déplacement interrompu'
    Write-Host '  6  Invite PowerShell'
    Write-Host '  7  Redémarrer'
    switch (Read-Choix 'Choix') {
        '1' { Show-Disques }
        '2' { Show-Disques; & (Join-Path $Racine 'Analyse-Partitions.ps1') -Disque ([int](Read-Choix 'Numéro du disque')) }
        '3' {
            Show-Disques
            $d = [int](Read-Choix 'Disque'); $p = [int](Read-Choix 'Partition (n°)')
            $dir = if ((Read-Choix 'Direction : G = vers la gauche (début du disque), D = vers la droite') -match '^[dD]') { 'Droite' } else { 'Gauche' }
            $j = Read-Choix 'Dossier du journal (sur la clé ou un AUTRE disque, ex. E:\Journal)'
            & (Join-Path $Ici 'Deplacer-Partition.ps1') -Disque $d -Partition $p -Direction $dir -DossierJournal $j
            if ((Read-Choix 'Lancer pour de vrai ? (O/N)') -match '^[oO]') {
                & (Join-Path $Ici 'Deplacer-Partition.ps1') -Disque $d -Partition $p -Direction $dir -DossierJournal $j -Executer
            }
        }
        '4' {
            Show-Disques
            $s = Read-Choix 'Lettre de la partition Windows source (ex. C)'; $c = [int](Read-Choix 'Numéro du disque CIBLE (sera effacé)')
            $f = Read-Choix 'Fichier image sur un troisième support (ex. E:\migration.wim)'
            & (Join-Path $Ici 'Migrer-Disque.ps1') -Source $s -DisqueCible $c -FichierImage $f
            if ((Read-Choix 'Lancer pour de vrai ? (O/N)') -match '^[oO]') {
                & (Join-Path $Ici 'Migrer-Disque.ps1') -Source $s -DisqueCible $c -FichierImage $f -Executer
            }
        }
        '5' {
            $js = @(Find-JournauxEnCours)
            if (-not $js) { Write-Host '  Aucun journal en cours.'; continue }
            & (Join-Path $Ici 'Deplacer-Partition.ps1') -Reprendre $js[0].FullName -Executer
        }
        '6' { Write-Host '  Tapez exit pour revenir au menu.'; powershell.exe -NoLogo -NoExit -ExecutionPolicy Bypass -Command ". '$Racine\lib\Commun.ps1'" }
        '7' {
            if (@(Find-JournauxEnCours).Count -gt 0) { Write-Host '  Un déplacement est inachevé : terminez-le (choix 5) avant de redémarrer.' -ForegroundColor Red; continue }
            wpeutil.exe reboot
        }
    }
}
