# Correction hors ligne de HKLM\SYSTEM\MountedDevices (lettres de lecteur) d'une installation Windows.
# Format des valeurs :
#   MBR : signature du disque (4 octets LE) + offset de la partition en octets (8 octets LE) = 12 octets
#   GPT : "DMIO:ID:" (8 octets ASCII) + GUID de la partition (16 octets) = 24 octets
# Sur GPT, le GUID ne change pas lors d'un déplacement : seule la migration vers un autre disque demande une correction.

Set-StrictMode -Version 3

function Get-IdentiteMontageMbr([uint32]$Signature, [int64]$Offset) {
    $b = New-Object byte[] 12
    [Array]::Copy([BitConverter]::GetBytes($Signature), 0, $b, 0, 4)
    [Array]::Copy([BitConverter]::GetBytes($Offset), 0, $b, 4, 8)
    return , $b
}

function Get-IdentiteMontageGpt([guid]$PartitionId) {
    $b = New-Object byte[] 24
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('DMIO:ID:'), 0, $b, 0, 8)
    [Array]::Copy($PartitionId.ToByteArray(), 0, $b, 8, 16)
    return , $b
}

function Test-OctetsEgaux([byte[]]$A, [byte[]]$B) {
    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) { return $false }
    for ($i = 0; $i -lt $A.Length; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
    return $true
}

function Invoke-RucheHorsLigne {
    <# Charge la ruche SYSTEM d'une Windows hors ligne, exécute $Action avec le chemin de MountedDevices, décharge. #>
    param([string]$RacineWindows, [scriptblock]$Action)
    $ruche = Join-Path $RacineWindows 'System32\config\SYSTEM'
    $cle = 'DP_SYSTEM_{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8))
    Invoke-Externe -Exe 'reg.exe' -Arguments @('load', "HKLM\$cle", $ruche) | Out-Null
    try { & $Action "HKLM:\$cle\MountedDevices" }
    finally {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        Invoke-Externe -Exe 'reg.exe' -Arguments @('unload', "HKLM\$cle") -Tolerant | Out-Null
    }
}

function Update-MountedDevicesDeplacement {
    <# Après déplacement d'une partition sur disque MBR : remplace l'ancienne identité par la nouvelle. #>
    param([string]$RacineWindows, [uint32]$Signature, [int64]$AncienOffset, [int64]$NouvelOffset)
    $ancien = Get-IdentiteMontageMbr $Signature $AncienOffset
    $nouveau = Get-IdentiteMontageMbr $Signature $NouvelOffset
    $compteur = [ref]0
    Invoke-RucheHorsLigne -RacineWindows $RacineWindows -Action {
        param($chemin)
        $k = Get-Item -LiteralPath $chemin
        foreach ($nom in $k.GetValueNames()) {
            $v = $k.GetValue($nom)
            if ($v -is [byte[]] -and (Test-OctetsEgaux $v $ancien)) {
                Set-ItemProperty -LiteralPath $chemin -Name $nom -Value $nouveau -Type Binary
                Write-Log "MountedDevices : $nom mis à jour (nouvelle position)." 'OK'
                $compteur.Value++
            }
        }
    }
    return $compteur.Value
}

function Set-LettreSystemeHorsLigne {
    <# Migration : fait pointer \DosDevices\C: vers la nouvelle partition Windows (évite un C: introuvable au démarrage). #>
    param([string]$RacineWindows, [byte[]]$Identite)
    Invoke-RucheHorsLigne -RacineWindows $RacineWindows -Action {
        param($chemin)
        $k = Get-Item -LiteralPath $chemin
        # Retire toute autre lettre qui pointerait déjà vers la nouvelle partition, pour éviter un doublon.
        foreach ($nom in $k.GetValueNames()) {
            if ($nom -like '\DosDevices\*' -and $nom -ne '\DosDevices\C:' -and (Test-OctetsEgaux $k.GetValue($nom) $Identite)) {
                Remove-ItemProperty -LiteralPath $chemin -Name $nom
            }
        }
        Set-ItemProperty -LiteralPath $chemin -Name '\DosDevices\C:' -Value $Identite -Type Binary
        Write-Log 'MountedDevices : \DosDevices\C: pointe vers la nouvelle partition Windows.' 'OK'
    }
}
