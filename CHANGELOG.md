# Changelog

## 0.2.0 (5 novembre 2026)

- `Operations.ps1` : Agrandir, Reduire, DeplacerRecovery (procédure Microsoft KB5028997), ReparerDemarrage, ReparerWinRE, RestaurerBcd, Verifier. Simulation par défaut, sauvegarde (table brute, BCD, ReAgent.xml, Winre.wim) avant, contrôle du démarrage après.
- WinPE : `Deplacer-Partition.ps1` (déplacement réel avec journal de reprise, table réécrite par IOCTL en conservant les GUID, hidden sectors, MountedDevices, ReAgent.xml, bcdboot), `Migrer-Disque.ps1` (DISM), `Menu.ps1` (reprise proposée au démarrage).
- `Creer-CleWinPE.ps1` : clé USB ou ISO WinPE avec PowerShell, stockage et BitLocker.
- Analyse compatible WinPE ; bibliothèque commune `lib\`.
- 53 tests de logique (copie avec coupures simulées, table de partitions, secteurs de démarrage, registre).
- Correctif : `DeplacerRecovery -TailleGo` refuse une taille inférieure à la taille actuelle.

## 0.1.0 (4 novembre 2026)

- `Analyse-Partitions.ps1` : analyse en lecture seule du disque système (disposition, BitLocker, WinRE, BCD, blocages).
