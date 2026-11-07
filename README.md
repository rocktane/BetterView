# BetterView

Visionneuse RAW pour macOS, faite pour trier des photos Sony A7C le plus vite possible.

- Passage d'une photo à l'autre en moins d'une milliseconde quand la photo est préparée.
- Suppression en une touche, vers la corbeille, annulable avec ⌘Z.
- Une fenêtre qui prend la forme de chaque photo, sans bordure ni barre de titre : on ne voit que la photo. Elle se déplace en glissant la photo.
- Au survol de la photo : boutons de fenêtre, nom, puis ISO, vitesse, ouverture et focale, puis date de prise de vue, et position dans le dossier. Rien quand le pointeur est ailleurs.
- Aucune dépendance, aucun catalogue : un dossier, des photos.

## Installation

Il faut macOS 14 ou plus récent, Xcode et `xcodegen` (`brew install xcodegen`). Le projet Xcode n'est pas versionné : il est généré depuis `project.yml`.

```sh
scripts/install.sh
```

L'app est copiée dans `/Applications`. Pour en faire l'app par défaut d'un format : Réglages (⌘,).

## Raccourcis

Ils se changent dans les Réglages (⌘,), avec plusieurs touches possibles par action. Valeurs par défaut :

| Touche | Action |
|---|---|
| ← → (ou ↑ ↓), Espace | Précédente, suivante |
| Page préc., Page suiv. | Reculer, avancer de 10 photos |
| Début, Fin | Première, dernière |
| ⌫, ⌦, X ou ⌘⌫ | Mettre à la corbeille, puis afficher la photo suivante |
| ⌘Z | Annuler la suppression |
| Z | 100 % ou ajusté |
| I | Informations |
| R | Afficher dans le Finder |
| Échap | Quitter le zoom |

Non modifiables : double-clic (100 % ou ajusté), pincement, défilement et glisser (zoom, déplacement), ⌘O, ⌘, ⌘W et ⌘Q.

Maintenir une touche de suppression ne supprime qu'une seule photo. Le marqueur « Aperçu » signale le JPEG embarqué, trop petit pour juger la netteté : le rendu RAW le remplace dès qu'il est prêt.

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
