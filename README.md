# Déplaceur de partitions

Outil Windows (PowerShell 5.1) pour agrandir, déplacer et migrer les partitions système
**sans casser le démarrage**.

## Principe : le démarrage d'abord

Une modification de partitions ne casse le démarrage que pour quelques raisons connues. L'outil les vérifie avant et après chaque opération :

| Cause de panne au démarrage | Garde-fou |
|---|---|
| BitLocker demande la clé de récupération | Suspension automatique avant l'opération |
| BCD qui pointe vers l'ancienne position (disque MBR) | `bcdboot` systématique après déplacement |
| GUID de partition changé (disque GPT) | GUID conservés lors des déplacements |
| WinRE perdu ou cassé | `reagentc /disable` avant, `/enable` après, vérification de ReAgent.xml |
| Partition EFI absente, trop petite, fichiers manquants | Contrôle de `bootmgfw.efi` et du BCD |
| Coupure de courant pendant un déplacement | Journal de reprise (mode WinPE) |

## Étapes

1. **Analyse** (lecture seule) : `Analyse-Partitions.ps1` ✅
2. Opérations en ligne : agrandir/réduire C:, déplacer Recovery en fin de disque, réparer le démarrage
3. Mode WinPE : déplacement réel du début de C:, migration vers un autre disque

## Utilisation

```powershell
# PowerShell en administrateur (sinon analyse partielle)
.\Analyse-Partitions.ps1
.\Analyse-Partitions.ps1 -Disque 1
```

Le rapport JSON est écrit dans `rapports\` (non publié : il décrit la machine).
