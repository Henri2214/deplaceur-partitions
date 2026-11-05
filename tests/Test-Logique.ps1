#Requires -Version 5.1
# Tests de la logique critique, sans toucher aux disques : .\tests\Test-Logique.ps1
$ErrorActionPreference = 'Stop'
$Racine = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($m in 'Commun', 'DisqueBrut', 'Copie', 'Registre') { . (Join-Path $Racine "lib\$m.ps1") }
$ProgressPreference = 'SilentlyContinue'

$script:ok = 0; $script:ko = 0
function Assert([bool]$Cond, [string]$Nom) {
    if ($Cond) { $script:ok++ } else { $script:ko++; Write-Host "  ÉCHEC : $Nom" -ForegroundColor Red }
}
function Test-Egal([byte[]]$A, [byte[]]$B) { return (Test-OctetsEgaux $A $B) }

# --- Taille de bloc -----------------------------------------------------------------------------------
Assert ((Get-TailleBloc (-300MB) 512) -eq 16MB) 'bloc plafonné à 16 Mo'
Assert ((Get-TailleBloc (1MB) 512) -eq 1MB) 'bloc = décalage quand décalage < 16 Mo'
Assert ((Get-TailleBloc (1536) 512) -eq 1536) 'petit décalage'
$err = $false; try { Get-TailleBloc 1000 512 | Out-Null } catch { $err = $true }; Assert $err 'décalage non multiple du secteur refusé'

# --- Moteur de copie : disque simulé en mémoire, coupures aléatoires --------------------------------------
$rnd = New-Object Random 42
function Invoke-CasCopie([int]$TailleDisque, [int64]$Src, [int64]$Dst, [int64]$Taille, [int]$Secteur, [int64]$BlocMax, [int]$Coupure) {
    $disque = New-Object byte[] $TailleDisque
    $rnd.NextBytes($disque)
    $attendu = New-Object byte[] $Taille
    [Array]::Copy($disque, $Src, $attendu, 0, $Taille)
    $bloc = Get-TailleBloc ($Dst - $Src) $Secteur $BlocMax
    $etat = [pscustomobject]@{ etape_faite = -1; maj = '' }
    $lire = { param($o, $l) $b = New-Object byte[] $l; [Array]::Copy($disque, $o, $b, 0, $l); , $b }
    $ecrire = { param($o, $d) [Array]::Copy($d, 0, $disque, $o, $d.Length) }
    # Coupure simulée : on écrit à moitié le bloc suivant (écriture interrompue), puis on reprend.
    $ecrireCoupe = {
        param($o, $d)
        $moitie = [int]($d.Length / 2) - ([int]($d.Length / 2) % $Secteur)
        [Array]::Copy($d, 0, $disque, $o, $moitie)
        throw 'COUPURE_SIMULEE'
    }
    $n = 0
    if ($Coupure -ge 0) {
        try {
            Invoke-CopieBlocs -Source $Src -Destination $Dst -Taille $Taille -Bloc $bloc -Lire $lire -Ecrire $ecrire -Vider {} -Etat $etat -Sauver {} -ArretApres $Coupure | Out-Null
        } catch { if ("$_" -notmatch 'COUPURE_SIMULEE') { throw } }
        # Écriture partielle du bloc en cours au moment de la coupure.
        $plan = Get-PlanCopie $Src $Dst $Taille $bloc
        $i = $etat.etape_faite + 1
        if ($i -lt $plan.Count) {
            $b = $plan[$i]; $donnees = & $lire ($Src + $b.rel) $b.longueur
            try { & $ecrireCoupe ($Dst + $b.rel) $donnees } catch { }
        }
    }
    Invoke-CopieBlocs -Source $Src -Destination $Dst -Taille $Taille -Bloc $bloc -Lire $lire -Ecrire $ecrire -Vider {} -Etat $etat -Sauver {} | Out-Null
    $obtenu = New-Object byte[] $Taille
    [Array]::Copy($disque, $Dst, $obtenu, 0, $Taille)
    return (Test-Egal $attendu $obtenu)
}

$cas = @(
    @{ n = 'gauche, grand décalage'; src = 65536; dst = 4096; t = 40960; bm = 4096 },
    @{ n = 'gauche, décalage 1 secteur'; src = 8192; dst = 7680; t = 30720; bm = 4096 },
    @{ n = 'gauche, chevauchement'; src = 20480; dst = 12288; t = 32768; bm = 4096 },
    @{ n = 'droite, grand décalage'; src = 4096; dst = 70000 - (70000 % 512); t = 40960; bm = 4096 },
    @{ n = 'droite, décalage 1 secteur'; src = 4096; dst = 4608; t = 30720; bm = 4096 },
    @{ n = 'droite, chevauchement'; src = 4096; dst = 10240; t = 33280; bm = 4096 },
    @{ n = 'taille non multiple du bloc'; src = 30720; dst = 1024; t = 25600 + 512; bm = 4096 }
)
foreach ($c in $cas) {
    Assert (Invoke-CasCopie 131072 $c.src $c.dst $c.t 512 $c.bm -1) "copie sans coupure : $($c.n)"
    foreach ($k in 0, 1, 3, 7) { Assert (Invoke-CasCopie 131072 $c.src $c.dst $c.t 512 $c.bm $k) "coupure après $k bloc(s) + reprise : $($c.n)" }
}
$err = $false
try { Invoke-CopieBlocs -Source 0 -Destination 512 -Taille 4096 -Bloc 1024 -Lire {} -Ecrire {} -Vider {} -Etat ([pscustomobject]@{ etape_faite = -1 }) -Sauver {} } catch { $err = $true }
Assert $err 'bloc > décalage refusé'

# --- Table de partitions : modification d'une entrée ----------------------------------------------------
function New-LayoutTest([uint32]$Style, [int]$N) {
    $b = New-Object byte[] (48 + 144 * $N)
    [Array]::Copy([BitConverter]::GetBytes($Style), 0, $b, 0, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]$N), 0, $b, 4, 4)
    for ($i = 0; $i -lt $N; $i++) {
        $o = 48 + 144 * $i
        [Array]::Copy([BitConverter]::GetBytes([int64](1MB * (1 + 100 * $i))), 0, $b, $o + 8, 8)
        [Array]::Copy([BitConverter]::GetBytes([int64](50MB)), 0, $b, $o + 16, 8)
        [Array]::Copy([BitConverter]::GetBytes([uint32]($i + 1)), 0, $b, $o + 24, 4)
        if ($Style -eq 1) { [Array]::Copy(([guid]::NewGuid()).ToByteArray(), 0, $b, $o + 48, 16); $b[$o + 64] = 0x01; $b[$o + 71] = 0x80 }
    }
    return , $b
}
$g = New-LayoutTest 1 3
$g2 = Set-OffsetLayout -B $g -Numero 2 -Nouvel (300MB) -TailleSecteur 512
$e = (ConvertFrom-LayoutBrut $g2).entrees
Assert ($e[1].offset -eq 300MB) 'GPT : nouvel offset écrit'
Assert ($e[0].offset -eq 1MB -and $e[2].offset -eq 201MB) 'GPT : autres entrées inchangées'
Assert (($g2[48 + 28] -eq 1) -and ($g2[48 + 144 + 28] -eq 1) -and ($g2[48 + 288 + 28] -eq 1)) 'GPT : RewritePartition sur toutes les entrées'
$o = 48 + 144
Assert (Test-Egal ([byte[]]$g[($o + 32)..($o + 143)]) ([byte[]]$g2[($o + 32)..($o + 143)])) 'GPT : type, GUID, attributs et nom conservés'
Assert ($e[1].id -eq ([guid][byte[]]$g[($o + 48)..($o + 63)]).ToString('B')) 'GPT : lecture du GUID de partition'
$m = New-LayoutTest 0 4
$m2 = Set-OffsetLayout -B $m -Numero 1 -Nouvel (2MB) -TailleSecteur 512
Assert ([BitConverter]::ToUInt32($m2, 48 + 36) -eq (2MB / 512)) 'MBR : hidden sectors de l''entrée mis à jour'
$err = $false; try { Set-OffsetLayout -B $g -Numero 9 -Nouvel 0 -TailleSecteur 512 | Out-Null } catch { $err = $true }
Assert $err 'partition absente : erreur'

# --- Secteur de démarrage -----------------------------------------------------------------------------------
$s = New-Object byte[] 512
[Array]::Copy([Text.Encoding]::ASCII.GetBytes('NTFS    '), 0, $s, 3, 8)
[Array]::Copy([BitConverter]::GetBytes([uint16]512), 0, $s, 11, 2)
[Array]::Copy([BitConverter]::GetBytes([uint32]2048), 0, $s, 0x1C, 4)
[Array]::Copy([BitConverter]::GetBytes([int64]1000000), 0, $s, 0x28, 8)
$s2 = Update-SecteurBoot $s (300MB)
Assert ([BitConverter]::ToUInt32($s2, 0x1C) -eq (300MB / 512)) 'NTFS : hidden sectors corrigé'
Assert ([BitConverter]::ToUInt32($s, 0x1C) -eq 2048) 'NTFS : secteur d''origine non modifié'
Assert ((Get-PositionSecoursBoot $s) -eq 1000000 * 512) 'NTFS : position de la copie de secours'
$f = New-Object byte[] 512
[Array]::Copy([Text.Encoding]::ASCII.GetBytes('-FVE-FS-'), 0, $f, 3, 8)
Assert ($null -eq (Update-SecteurBoot $f 1MB)) 'BitLocker : secteur laissé intact'

# --- Identités MountedDevices ----------------------------------------------------------------------------------
$id = Get-IdentiteMontageMbr 0x12345678 (1MB)
Assert ($id.Length -eq 12 -and $id[0] -eq 0x78 -and [BitConverter]::ToInt64($id, 4) -eq 1MB) 'identité MBR'
$gg = [guid]'0b2f4a3c-1111-2222-3333-444455556666'
$id = Get-IdentiteMontageGpt $gg
Assert ($id.Length -eq 24 -and [Text.Encoding]::ASCII.GetString($id, 0, 8) -eq 'DMIO:ID:' -and ([guid][byte[]]$id[8..23]) -eq $gg) 'identité GPT'

# --- Lecture réelle de la table (lecture seule, administrateur) ------------------------------------------------
if (Test-Admin) {
    $d = (Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':'))).DiskNumber
    $lay = ConvertFrom-LayoutBrut (Read-LayoutBrut $d)
    $ps = @(Get-Partition -DiskNumber $d)
    foreach ($p in $ps) {
        $e = $lay.entrees | Where-Object { $_.numero -eq $p.PartitionNumber -and $_.taille -gt 0 }
        Assert ($e -and $e.offset -eq $p.Offset -and $e.taille -eq $p.Size) "table réelle : partition n°$($p.PartitionNumber) relue à l'identique"
        if ($lay.style -eq 'GPT') { Assert ($e.id -eq $p.Guid) "table réelle : GUID de la partition n°$($p.PartitionNumber)" }
    }
} else { Write-Host '  (lecture réelle de la table ignorée : pas administrateur)' -ForegroundColor DarkGray }

Write-Host ''
Write-Host ("  {0} réussis, {1} échoués" -f $script:ok, $script:ko) -ForegroundColor $(if ($script:ko) { 'Red' } else { 'Green' })
if ($script:ko) { exit 1 }
