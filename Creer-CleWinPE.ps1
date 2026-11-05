#Requires -Version 5.1
<#
.SYNOPSIS
    Crée la clé USB (ou l'ISO) WinPE qui démarre directement sur le menu du déplaceur de partitions.
.DESCRIPTION
    Prérequis (gratuits, Microsoft) : Windows ADK + module complémentaire WinPE
    https://learn.microsoft.com/windows-hardware/get-started/adk-install
    Composants ajoutés : WMI, .NET, scripts, PowerShell, cmdlets de stockage, DISM, BitLocker (SecureStartup),
    en français si les paquets fr-fr sont présents. L'outil est copié dans X:\Outils\Deplaceur.
.EXAMPLE
    .\Creer-CleWinPE.ps1 -Iso C:\Temp\deplaceur.iso
    .\Creer-CleWinPE.ps1 -Cle F:          # LA CLÉ F: EST EFFACÉE
#>
[CmdletBinding()]
param(
    [string]$Iso = '',
    [string]$Cle = '',
    [string]$Travail = "$env:TEMP\deplaceur_winpe",
    [switch]$Executer
)
$ErrorActionPreference = 'Stop'
$Racine = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Racine 'lib\Commun.ps1')
$script:Executer = [bool]$Executer
if (-not (Test-Admin)) { throw 'Droits administrateur requis.' }
if (-not $Iso -and -not $Cle) { throw 'Précisez -Iso <fichier.iso> ou -Cle <lettre:>.' }

$adk = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit'
$pe = Join-Path $adk 'Windows Preinstallation Environment'
$env_ = Join-Path $adk 'Deployment Tools\DandISetEnv.bat'
if (-not (Test-Path -LiteralPath (Join-Path $pe 'amd64'))) {
    throw "Module WinPE de l'ADK introuvable ($pe). Installez « Windows ADK » puis « WinPE add-on » : https://learn.microsoft.com/windows-hardware/get-started/adk-install"
}
$ocs = Join-Path $pe 'amd64\WinPE_OCs'
$composants = 'WinPE-WMI', 'WinPE-NetFx', 'WinPE-Scripting', 'WinPE-PowerShell', 'WinPE-StorageWMI', 'WinPE-DismCmdlets', 'WinPE-SecureStartup', 'WinPE-EnhancedStorage'
$mount = Join-Path $Travail 'mount'
$wim = Join-Path $Travail 'media\sources\boot.wim'

if ($Cle) {
    $l = $Cle.TrimEnd(':', '\').ToUpper()
    $d = Get-Partition -DriveLetter $l | Get-Disk
    if ($d.BusType -ne 'USB') { throw "$($l): n'est pas une clé USB ($($d.BusType)) : refusé par sécurité." }
    Write-Log "Clé cible : $($l): - $($d.FriendlyName) $(Format-Taille $d.Size) (sera EFFACÉE)" 'ATTENTION'
}

Invoke-Etape "Préparation de l'espace de travail WinPE ($Travail)" {
    if (Test-Path -LiteralPath $Travail) { Remove-Item -LiteralPath $Travail -Recurse -Force }
    Invoke-Externe -Exe 'cmd.exe' -Arguments @('/c', "call `"$env_`" && copype amd64 `"$Travail`"") | Out-Null
} | Out-Null

Invoke-Etape 'Montage de boot.wim et ajout des composants (PowerShell, stockage, BitLocker…)' {
    Invoke-Externe -Exe 'dism.exe' -Arguments @('/Mount-Image', "/ImageFile:$wim", '/Index:1', "/MountDir:$mount") | Out-Null
    try {
        foreach ($c in $composants) {
            Invoke-Externe -Exe 'dism.exe' -Arguments @("/Image:$mount", '/Add-Package', "/PackagePath:$(Join-Path $ocs "$c.cab")") | Out-Null
            $fr = Join-Path $ocs "fr-fr\$($c)_fr-fr.cab"
            if (Test-Path -LiteralPath $fr) { Invoke-Externe -Exe 'dism.exe' -Arguments @("/Image:$mount", '/Add-Package', "/PackagePath:$fr") | Out-Null }
            Write-Log "Composant ajouté : $c" 'OK'
        }
        $fr = Join-Path $ocs 'fr-fr\lp.cab'
        if (Test-Path -LiteralPath $fr) {
            Invoke-Externe -Exe 'dism.exe' -Arguments @("/Image:$mount", '/Add-Package', "/PackagePath:$fr") | Out-Null
            Invoke-Externe -Exe 'dism.exe' -Arguments @("/Image:$mount", '/Set-AllIntl:fr-FR') | Out-Null
        }
        Invoke-Externe -Exe 'dism.exe' -Arguments @("/Image:$mount", '/Set-InputLocale:040c:0000040c') | Out-Null

        $outil = Join-Path $mount 'Outils\Deplaceur'
        New-Item -ItemType Directory -Force -Path $outil | Out-Null
        foreach ($e in 'lib', 'WinPE', 'Analyse-Partitions.ps1', 'Operations.ps1', 'README.md') {
            Copy-Item -LiteralPath (Join-Path $Racine $e) -Destination $outil -Recurse -Force
        }
        Set-Content -LiteralPath (Join-Path $mount 'Windows\System32\startnet.cmd') -Encoding ASCII -Value @(
            'wpeinit',
            'wpeutil SetKeyboardLayout 040c:0000040c',
            'powercfg /s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c',
            'powershell.exe -NoLogo -ExecutionPolicy Bypass -NoExit -File X:\Outils\Deplaceur\WinPE\Menu.ps1'
        )
        Write-Log 'Outil copié et lancement automatique configuré.' 'OK'
        Invoke-Externe -Exe 'dism.exe' -Arguments @('/Unmount-Image', "/MountDir:$mount", '/Commit') | Out-Null
    } catch {
        Invoke-Externe -Exe 'dism.exe' -Arguments @('/Unmount-Image', "/MountDir:$mount", '/Discard') -Tolerant | Out-Null
        throw
    }
} | Out-Null

if ($Iso) {
    Invoke-Etape "Création de l'ISO $Iso" {
        Invoke-Externe -Exe 'cmd.exe' -Arguments @('/c', "call `"$env_`" && MakeWinPEMedia /ISO /F `"$Travail`" `"$Iso`"") | Out-Null
    } | Out-Null
}
if ($Cle) {
    if (-not (Confirm-Operation "Effacer la clé $($Cle) et y écrire WinPE ?")) { Write-Log 'Annulé.' 'ATTENTION'; return }
    Invoke-Etape "Écriture de la clé $Cle" {
        Invoke-Externe -Exe 'cmd.exe' -Arguments @('/c', "call `"$env_`" && echo Y | MakeWinPEMedia /UFD `"$Travail`" $($Cle.TrimEnd('\'))") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path "$($Cle.TrimEnd('\'))\" 'Journal') | Out-Null
    } | Out-Null
}
Write-Log 'Terminé. Démarrez le PC sur la clé (F12/F8/Échap selon le fabricant).' 'OK'
if ($Cle) { Write-Log "Le dossier $($Cle.TrimEnd('\'))\Journal de la clé est prévu pour les journaux de reprise." 'INFO' }
