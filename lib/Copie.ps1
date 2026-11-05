# Moteur de déplacement de données avec reprise après coupure.
#
# Garantie : la taille de bloc ne dépasse jamais le décalage |destination - source|.
#  - vers la gauche, on copie du début vers la fin ; vers la droite, de la fin vers le début ;
#  - l'écriture d'un bloc ne touche donc ni sa propre source, ni celle des blocs restant à copier ;
#  - après une coupure, le bloc interrompu se recopie depuis sa source, qui est intacte.
# Le journal ne stocke qu'un compteur (pas de copie des données), écrit après chaque bloc vidé sur le disque.

Set-StrictMode -Version 3

function Get-TailleBloc([int64]$Decalage, [int]$TailleSecteur, [int64]$Max = 16MB) {
    $d = [math]::Abs($Decalage)
    if ($d -eq 0) { throw 'Décalage nul : rien à déplacer.' }
    if ($d % $TailleSecteur -ne 0) { throw "Le décalage ($d) n'est pas un multiple de la taille de secteur ($TailleSecteur)." }
    $b = [math]::Min($Max, $d)
    return [int64]($b - ($b % $TailleSecteur))
}

function Get-PlanCopie {
    <# Liste ordonnée des blocs à copier (positions relatives au début de la zone). Fonction pure. #>
    param([int64]$Source, [int64]$Destination, [int64]$Taille, [int64]$Bloc)
    $n = [int64][math]::Ceiling($Taille / $Bloc)
    $plan = New-Object System.Collections.Generic.List[object]
    for ($k = 0; $k -lt $n; $k++) {
        $rel = $k * $Bloc
        $plan.Add([pscustomobject]@{ rel = [int64]$rel; longueur = [int]([math]::Min($Bloc, $Taille - $rel)) })
    }
    if ($Destination -gt $Source) { $plan.Reverse() }
    return , $plan.ToArray()
}

function Write-FichierSur([string]$Chemin, [string]$Texte) {
    <# Écriture atomique et vidée sur le support (survit à une coupure de courant). #>
    $tmp = "$Chemin.tmp"
    $fs = New-Object IO.FileStream($tmp, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try {
        $b = [Text.Encoding]::UTF8.GetBytes($Texte)
        $fs.Write($b, 0, $b.Length)
        $fs.Flush($true)
    } finally { $fs.Dispose() }
    Move-Item -LiteralPath $tmp -Destination $Chemin -Force
}

function Read-JournalDeplacement([string]$Chemin) {
    if (-not (Test-Path -LiteralPath $Chemin)) { return $null }
    return (Get-Content -LiteralPath $Chemin -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-JournalDeplacement([string]$Chemin, $Etat) {
    $Etat.maj = (Get-Date).ToString('s')
    Write-FichierSur $Chemin ($Etat | ConvertTo-Json -Depth 4)
}

function Invoke-CopieBlocs {
    <#
      Copie [Source, Source+Taille) vers Destination sur le même support.
      $Lire   : { param([int64]$offset, [int]$longueur) ; renvoie byte[] }
      $Ecrire : { param([int64]$offset, [byte[]]$donnees) }
      $Vider  : { } (vidage du cache matériel)
      $Etat   : objet du journal (champ etape_faite = dernier bloc écrit, -1 au départ) ; sauvegardé via $Sauver.
    #>
    param(
        [Parameter(Mandatory)][int64]$Source, [Parameter(Mandatory)][int64]$Destination, [Parameter(Mandatory)][int64]$Taille,
        [Parameter(Mandatory)][int64]$Bloc, [Parameter(Mandatory)][scriptblock]$Lire, [Parameter(Mandatory)][scriptblock]$Ecrire,
        [Parameter(Mandatory)][scriptblock]$Vider, [Parameter(Mandatory)]$Etat, [Parameter(Mandatory)][scriptblock]$Sauver,
        [int]$ArretApres = -1   # pour les tests : simule une coupure après N blocs
    )
    if ($Bloc -gt [math]::Abs($Destination - $Source)) { throw 'Bloc supérieur au décalage : reprise non garantie, refusé.' }
    $plan = Get-PlanCopie -Source $Source -Destination $Destination -Taille $Taille -Bloc $Bloc
    $debut = [int]$Etat.etape_faite + 1
    $chrono = [Diagnostics.Stopwatch]::StartNew()
    $copie = [int64]0
    for ($i = $debut; $i -lt $plan.Count; $i++) {
        if ($ArretApres -ge 0 -and ($i - $debut) -ge $ArretApres) { throw 'COUPURE_SIMULEE' }
        $b = $plan[$i]
        $donnees = & $Lire ($Source + $b.rel) $b.longueur
        & $Ecrire ($Destination + $b.rel) $donnees
        & $Vider
        $Etat.etape_faite = $i
        & $Sauver $Etat
        $copie += $b.longueur
        if ($i % 32 -eq 0 -or $i -eq $plan.Count - 1) {
            $pct = [math]::Round(100 * ($i + 1) / $plan.Count, 1)
            $debit = if ($chrono.Elapsed.TotalSeconds -gt 0) { $copie / $chrono.Elapsed.TotalSeconds } else { 0 }
            $reste = if ($debit -gt 0) { [TimeSpan]::FromSeconds(($Taille - ($i + 1) * $Bloc) / $debit) } else { [TimeSpan]::Zero }
            Write-Progress -Activity 'Déplacement des données' -Status ("{0} % - {1}/s - reste {2:hh\:mm\:ss}" -f $pct, (Format-Taille $debit), $reste) -PercentComplete $pct
        }
    }
    Write-Progress -Activity 'Déplacement des données' -Completed
    return $plan.Count
}
