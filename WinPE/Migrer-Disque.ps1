#Requires -Version 5.1
<#
.SYNOPSIS
    Migre une installation Windows vers un autre disque (SSD plus petit ou plus grand), depuis WinPE.
.DESCRIPTION
    Méthode par image (DISM capture puis application) : fiable, indépendante de la taille du disque cible
    (il suffit que les données tiennent), et réaligne tout sur 1 Mo.
      1. capture de la partition Windows source dans un fichier .wim (sur un TROISIÈME support)
      2. partitionnement du disque cible selon la disposition Microsoft (EFI 260 Mo, MSR 16 Mo, Windows, Recovery)
      3. application de l'image, puis bcdboot
      4. WinRE copié et enregistré, lettre C: corrigée dans le registre (MountedDevices)
    LE DISQUE CIBLE EST ENTIÈREMENT EFFACÉ. SIMULATION PAR DÉFAUT : ajoutez -Executer.
.EXAMPLE
    .\Migrer-Disque.ps1 -Source C -DisqueCible 1 -FichierImage E:\migration.wim
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][int]$DisqueCible,
    [Parameter(Mandatory)][string]$FichierImage,
    [int]$TailleRecoveryMo = 1024,
    [switch]$Executer
)

$ErrorActionPreference = 'Stop'
$Racine = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($m in 'Commun', 'DisqueBrut', 'Registre') { . (Join-Path $Racine "lib\$m.ps1") }
$script:Executer = [bool]$Executer
if (-not (Test-Admin)) { throw 'Droits administrateur requis.' }
if (-not (Test-WinPE)) { throw 'La migration se fait depuis WinPE (la Windows source ne doit pas être en cours d''exécution).' }

$Source = $Source.TrimEnd(':', '\').ToUpper()
$src = Get-Partition -DriveLetter $Source
if (-not (Test-Path -LiteralPath "$($Source):\Windows\System32\config\SYSTEM")) {
    throw "Pas de Windows lisible sur $($Source): (partition chiffrée ? déverrouillez-la : manage-bde -unlock $($Source): -RecoveryPassword <clé>)."
}
$cible = Get-Disk -Number $DisqueCible
if ($cible.Number -eq $src.DiskNumber) { throw 'Le disque cible est le disque source.' }
$imgLettre = (Split-Path -Qualifier ([IO.Path]::GetFullPath($FichierImage))).TrimEnd(':')
$imgPart = Get-Partition -DriveLetter $imgLettre -ErrorAction SilentlyContinue
if ($imgLettre -eq 'X') { throw 'X: est en mémoire : placez l''image sur un disque externe ou la clé USB.' }
if ($imgPart -and $imgPart.DiskNumber -in $cible.Number) { throw 'L''image ne peut pas être sur le disque cible (il va être effacé).' }
if ($imgLettre -eq $Source) { throw 'L''image ne peut pas être écrite sur la partition source.' }

$vol = Get-Volume -DriveLetter $Source
$utilise = [int64]$vol.Size - [int64]$vol.SizeRemaining
$firmware = Get-Firmware
$style = if ($firmware -eq 'UEFI') { 'GPT' } else { 'MBR' }
$fixe = 260MB + 16MB + [int64]$TailleRecoveryMo * 1MB + 4MB
$tailleWin = [int64]$cible.Size - $fixe
Write-Log ("Source  : {0}: ({1} utilisés sur {2})" -f $Source, (Format-Taille $utilise), (Format-Taille $vol.Size))
Write-Log ("Cible   : disque {0} - {1} - {2} -> {3}, Windows {4}" -f $cible.Number, $cible.FriendlyName, (Format-Taille $cible.Size), $style, (Format-Taille $tailleWin))
if ($tailleWin -lt $utilise * 1.1 + 2GB) { throw 'Disque cible trop petit pour les données utilisées (+10 % de marge).' }
$libreImg = (Get-PSDrive -Name $imgLettre).Free
if ($libreImg -lt $utilise * 0.8) { Write-Log "Espace libre sur $($imgLettre): ($(Format-Taille $libreImg)) peut-être insuffisant pour l'image." 'ATTENTION' }
Get-Partition -DiskNumber $cible.Number -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Log ("  sera effacée : partition n°{0} {1} {2}" -f $_.PartitionNumber, (Get-LettrePartition $_), (Format-Taille $_.Size)) 'ATTENTION'
}
if (-not $script:Executer) { Write-Log 'Simulation : rien n''a été modifié. Ajoutez -Executer pour migrer.' 'SIMULATION'; return }

Write-Host ''
$r = Read-Host "  Le disque $($cible.Number) ($($cible.FriendlyName)) va être EFFACÉ. Retapez son numéro pour confirmer"
if ($r -ne "$($cible.Number)") { Write-Log 'Annulé.' 'ATTENTION'; return }

$dossier = New-DossierSauvegarde (Split-Path -Parent ([IO.Path]::GetFullPath($FichierImage))) 'migration'
$S = Get-LettreLibre 'STUVQ'
$W = Get-LettreLibre ('WVUTQPONM' -replace $S, '')
$R = Get-LettreLibre ('RQPONMLK' -replace "[$S$W]", '')

Invoke-Etape "Capture de $($Source): vers $FichierImage (DISM, peut durer longtemps)" {
    Invoke-Externe -Exe 'dism.exe' -Arguments @('/Capture-Image', "/ImageFile:$FichierImage", "/CaptureDir:$($Source):\", '/Name:Migration', '/Compress:fast', '/CheckIntegrity') | Out-Null
} | Out-Null

Invoke-Etape "Partitionnement du disque $($cible.Number) ($style)" {
    $l = @("select disk $($cible.Number)", 'clean')
    if ($style -eq 'GPT') {
        $l += 'convert gpt', 'create partition efi size=260', 'format quick fs=fat32 label="System"', "assign letter=$S",
              'create partition msr size=16', 'create partition primary', "shrink minimum=$TailleRecoveryMo",
              'format quick fs=ntfs label="Windows"', "assign letter=$W",
              'create partition primary', 'format quick fs=ntfs label="Windows RE tools"', "assign letter=$R",
              "set id=`"$($GPT.Recovery.Trim('{}'))`"", "gpt attributes=$script:AttributsRecovery"
    } else {
        $l += 'convert mbr', 'create partition primary size=100', 'format quick fs=ntfs label="System"', 'active', "assign letter=$S",
              'create partition primary', "shrink minimum=$TailleRecoveryMo", 'format quick fs=ntfs label="Windows"', "assign letter=$W",
              'create partition primary', 'format quick fs=ntfs label="Windows RE tools"', 'set id=27', "assign letter=$R"
    }
    Invoke-Diskpart $l | Out-Null
} | Out-Null

Invoke-Etape "Application de l'image sur $($W):" {
    Invoke-Externe -Exe 'dism.exe' -Arguments @('/Apply-Image', "/ImageFile:$FichierImage", '/Index:1', "/ApplyDir:$($W):\", '/CheckIntegrity', '/Verify') | Out-Null
} | Out-Null

Invoke-Etape "Création du démarrage (bcdboot $($W):\Windows /s $($S): /f $firmware)" {
    Invoke-Externe -Exe 'bcdboot.exe' -Arguments @("$($W):\Windows", '/s', "$($S):", '/f', $firmware) | Out-Null
    $f = if ($firmware -eq 'UEFI') { "$($S):\EFI\Microsoft\Boot\bootmgfw.efi" } else { "$($S):\bootmgr" }
    if (-not (Test-Path -LiteralPath $f)) { throw "Fichier de démarrage absent : $f" }
} | Out-Null

Invoke-Etape 'Copie et enregistrement de WinRE' {
    $wimCible = "$($R):\Recovery\WindowsRE"
    New-Item -ItemType Directory -Force -Path $wimCible | Out-Null
    $wim = "$($W):\Windows\System32\Recovery\Winre.wim"
    if (-not (Test-Path -LiteralPath $wim)) {
        $wre = Get-WinRE "$($Source):\Windows"
        $pRec = if ($wre.offset) { Get-Partition -DiskNumber $src.DiskNumber | Where-Object { [int64]$_.Offset -eq $wre.offset } } else { $null }
        if ($pRec) {
            $m = Mount-PartitionTemporaire $pRec
            try { $wim = Join-Path "$($m.lettre)\" 'Recovery\WindowsRE\Winre.wim'; Copy-Item -LiteralPath $wim -Destination $wimCible -Force }
            finally { Dismount-PartitionTemporaire $m }
            $wim = $null
        }
    }
    if ($wim) { Copy-Item -LiteralPath $wim -Destination $wimCible -Force; Remove-Item -LiteralPath $wim -Force -ErrorAction SilentlyContinue }
    if (-not (Test-Path -LiteralPath "$wimCible\Winre.wim")) { Write-Log 'Image WinRE introuvable : WinRE à réinstaller plus tard (reagentc).' 'ATTENTION'; return }
    $r = Invoke-Externe -Exe "$($W):\Windows\System32\reagentc.exe" -Arguments @('/setreimage', '/path', $wimCible, '/target', "$($W):\Windows") -Tolerant
    if ($r.code -eq 0) { Write-Log 'WinRE enregistré.' 'OK' } else { Write-Log 'Enregistrement WinRE à faire après démarrage : Operations.ps1 -Action ReparerWinRE.' 'ATTENTION' }
} | Out-Null

Invoke-Etape 'Lettre C: de la nouvelle installation (MountedDevices)' {
    $pW = Get-Partition -DriveLetter $W
    $id = if ($style -eq 'GPT') { Get-IdentiteMontageGpt ([guid]$pW.Guid) }
          else { Get-IdentiteMontageMbr ([uint32](Get-Disk -Number $cible.Number).Signature) ([int64]$pW.Offset) }
    Set-LettreSystemeHorsLigne -RacineWindows "$($W):\Windows" -Identite $id
} | Out-Null

foreach ($l in $S, $R) {
    $p = Get-Partition -DriveLetter $l -ErrorAction SilentlyContinue
    if ($p) { Remove-PartitionAccessPath -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber -AccessPath "$($l):\" -ErrorAction SilentlyContinue }
}
Write-Log 'Migration terminée.' 'OK'
Write-Log 'Avant de redémarrer : débranchez l''ancien disque, ou choisissez le nouveau disque en premier dans le firmware (F2/Suppr/F12).' 'ATTENTION'
Write-Log "Le fichier image $FichierImage peut être supprimé une fois le nouveau disque validé." 'INFO'
