# BetterView

Visionneuse RAW pour macOS, faite pour trier des photos Sony A7C le plus vite possible.

- Passage d'une photo à l'autre en moins d'une milliseconde quand la photo est préparée.
- Suppression en une touche, vers la corbeille, annulable avec ⌘Z.
- Aucune dépendance, aucun catalogue : un dossier, des photos.

## Installation

Il faut macOS 14 ou plus récent, Xcode et `xcodegen` (`brew install xcodegen`). Le projet Xcode n'est pas versionné : il est généré depuis `project.yml`.

```sh
scripts/install.sh
```

L'app est copiée dans `/Applications`. Pour en faire l'app par défaut d'un format : Réglages (⌘,).

## Raccourcis

| Touche | Action |
|---|---|
| ← → (ou ↑ ↓) | Précédente, suivante |
| ⌫ ou X | Mettre à la corbeille |
| ⌘Z | Annuler la suppression |
| Z ou double-clic | 100 % ou ajusté |
| Pincement, défilement, glisser | Zoom, déplacement |
| Échap | Quitter le zoom ou le plein écran |
| F | Plein écran |
| I | Informations |
| Début, Fin | Première, dernière |
| ⌘O | Ouvrir |
| ⌘, | Réglages |

Maintenir ⌫ ne supprime qu'une seule photo. Le marqueur « Aperçu » signale le JPEG embarqué, trop petit pour juger la netteté : le rendu RAW le remplace dès qu'il est prêt.

## Développement

```sh
xcodegen generate
xcodebuild test -scheme BetterView -destination 'platform=macOS'
```

Mesures sur de vrais fichiers, sans jamais toucher au dossier (build Release) :

```sh
BetterView.app/Contents/MacOS/BetterView --bench <dossier>
BetterView.app/Contents/MacOS/BetterView --verify-previews <dossier>
```

Architecture, décisions et résultats mesurés : [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
