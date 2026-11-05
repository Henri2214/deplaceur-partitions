# Déplaceur de partitions

Outil Windows (PowerShell 5.1, aucune installation) pour agrandir, réduire, déplacer et migrer les partitions
système **sans casser le démarrage**. Développé à partir de la documentation publique Microsoft
(GPT, BCD, WinRE, BitLocker, IOCTL disque), sans code tiers.

> ⚠️ **État : code complet, non validé sur matériel réel.** Les opérations qui modifient les disques n'ont été
> exécutées qu'en simulation. Testez d'abord dans une machine virtuelle (Hyper-V/VirtualBox) avant un vrai PC,
> et ayez une sauvegarde de vos données.

## Principe : le démarrage d'abord

| Cause de panne au démarrage | Garde-fou |
|---|---|
| BitLocker demande la clé de récupération | Suspension automatique (1 redémarrage) avant bcdboot / modification de partitions |
| BCD qui pointe vers l'ancienne position (MBR) | `bcdboot` systématique après déplacement |
| Lettre C: introuvable au démarrage (MBR, migration) | Correction hors ligne de `MountedDevices` dans le registre |
| GUID de partition changé (GPT) | Table réécrite entrée par entrée : GUID, type, attributs et nom conservés |
| WinRE perdu | `reagentc /disable` → image vérifiée et sauvegardée → `/enable`, ReAgent.xml corrigé hors ligne |
| Secteur de démarrage incohérent | Champ « hidden sectors » NTFS/FAT32 corrigé (secteur principal + copie de secours) |
| Coupure de courant pendant un déplacement | Journal de reprise ; bloc ≤ décalage, donc la source du bloc interrompu est toujours intacte |
| Erreur de manipulation | Simulation par défaut, `-Executer` + confirmation, sauvegarde table/BCD/WinRE avant chaque opération |

Après chaque opération, la chaîne de démarrage est contrôlée (fichiers EFI, BCD, WinRE, BitLocker). Si un contrôle
échoue, l'outil dit **de ne pas redémarrer** et quelle réparation lancer.

## Contenu

| Fichier | Rôle | Où |
|---|---|---|
| `Analyse-Partitions.ps1` | Analyse en lecture seule : disposition, blocages, ce qui est faisable | Windows / WinPE |
| `Operations.ps1` | Agrandir, Réduire, DeplacerRecovery, ReparerDemarrage, ReparerWinRE, RestaurerBcd, Verifier | Windows |
| `WinPE\Deplacer-Partition.ps1` | Déplacement réel d'une partition (y compris C:), avec reprise | WinPE |
| `WinPE\Migrer-Disque.ps1` | Migration de Windows vers un autre disque (DISM, bcdboot, WinRE, lettre C:) | WinPE |
| `WinPE\Menu.ps1` | Menu de la clé, détecte et propose la reprise d'un déplacement interrompu | WinPE |
| `Creer-CleWinPE.ps1` | Fabrique la clé USB ou l'ISO WinPE (nécessite l'ADK Windows + module WinPE) | Windows |
| `lib\` | Fonctions communes, accès disque brut (IOCTL), moteur de copie, registre hors ligne | |
| `tests\Test-Logique.ps1` | Tests sans toucher aux disques (copie avec coupures simulées, table, secteurs, registre) | |

## Utilisation

PowerShell **en administrateur** (la simulation et l'analyse fonctionnent aussi sans, en partie).

```powershell
.\Analyse-Partitions.ps1                              # que se passe-t-il sur mon disque ?

# Partition de récupération collée derrière C: (cas le plus fréquent)
.\Operations.ps1 -Action DeplacerRecovery             # affiche le plan
.\Operations.ps1 -Action DeplacerRecovery -Executer   # l'applique

.\Operations.ps1 -Action Agrandir -Executer           # C: au maximum de l'espace libre qui la suit
.\Operations.ps1 -Action Reduire -TailleGo 150 -Executer
.\Operations.ps1 -Action Verifier                     # contrôle du démarrage
.\Operations.ps1 -Action ReparerDemarrage -Executer   # bcdboot, BitLocker suspendu
```

### Espace libre AVANT C: (déplacement réel)

1. Installer [Windows ADK + module WinPE](https://learn.microsoft.com/windows-hardware/get-started/adk-install).
2. `.\Creer-CleWinPE.ps1 -Cle F: -Executer` (la clé est effacée) ou `-Iso C:\Temp\deplaceur.iso -Executer`.
3. Démarrer sur la clé : le menu s'ouvre. Choix 3, partition, direction « Gauche », journal sur la clé (`F:\Journal`).
4. Au redémarrage sous Windows : `.\Operations.ps1 -Action Agrandir -Executer`.

En cas de coupure : **ne démarrez pas Windows**, redémarrez sur la clé : le menu propose la reprise.

## Tests

```powershell
.\tests\Test-Logique.ps1     # 53 tests (+ relecture de la vraie table en administrateur)
```

Les tests de copie simulent un disque en mémoire, déplacent vers la gauche et la droite (avec ou sans
chevauchement), coupent l'alimentation à différents moments avec un bloc écrit à moitié, reprennent, et
vérifient le résultat octet par octet.

## Limites connues

- Pas encore de redimensionnement *pendant* un déplacement (déplacer puis agrandir/réduire en deux temps).
- Déplacement : copie de toute la partition (pas seulement les clusters utilisés) : environ 25 min pour 236 Go à 150 Mo/s.
- Disques dynamiques, Storage Spaces et RAID logiciel non pris en charge.
- La migration produit une Windows non chiffrée : réactivez BitLocker ensuite si besoin.
