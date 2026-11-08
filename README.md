# BetterView

Visionneuse RAW pour macOS, faite pour trier des photos Sony A7C le plus vite possible.

- Passage d'une photo à l'autre en moins d'une milliseconde quand la photo est préparée.
- Suppression en une touche, vers la corbeille, annulable avec ⌘Z.
- Une fenêtre qui prend la forme de chaque photo, sans bordure ni barre de titre : on ne voit que la photo. Elle se déplace en glissant la photo.
- Au survol de la photo : boutons de fenêtre, nom, puis ISO, vitesse, ouverture et focale, puis date de prise de vue, et position dans le dossier. Rien quand le pointeur est ailleurs.
- Une bande d'aperçu flottante, détachée de la fenêtre : les photos d'avant et d'après, et les rafales repérées. Elle se déplace en la glissant et s'aimante au Dock et au centre de l'écran.
- Une vue Comparer pour garder la meilleure de plusieurs photos : jusqu'à 4 côte à côte, zoom à 100 % synchronisé, et corbeille directement depuis cette vue.
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
| A | 100 % sur le point AF enregistré, ou ajusté |
| I | Informations |
| R | Afficher dans le Finder |
| Échap | Quitter le zoom, puis la comparaison |
| B | Afficher ou masquer la bande d'aperçu |
| C | Comparer les photos, ou quitter la comparaison |
| ↩ | Dans la comparaison : garder la photo choisie |

Non modifiables : double-clic (100 % ou ajusté), pincement, défilement et glisser (zoom, déplacement), ⌘O, ⌘, ⌘W et ⌘Q. Dans la comparaison, les touches 1 à 4 choisissent une photo.

## Bande d'aperçu et comparaison

La bande est une pellicule : chaque vignette a la forme de sa photo, la photo courante reste au milieu, et la bande cesse de défiler aux extrémités du dossier pour rester remplie. Clic : aller à cette photo. Maj+clic : la sélectionner pour la comparer. Glisser, y compris depuis une vignette : déplacer la bande. Elle disparaît pendant un zoom et sa position est conservée.

`C` compare, dans cet ordre de préférence : les photos sélectionnées, la rafale de la photo courante (photos consécutives prises à 2 s d'écart au plus), ou la photo courante et la suivante.

Dans la comparaison, ← → (ou un clic) choisissent une photo. ⌫ la met à la corbeille, et la photo suivante du groupe prend sa place sans que les autres bougent. ↩ garde la photo choisie et met à la corbeille les autres photos affichées, jamais celles encore en attente. ⌘Z annule tout le geste d'un coup. Quand il ne reste qu'une photo, on revient à la vue normale, où ⌘Z reste possible.

Maintenir une touche de suppression ne supprime qu'une seule photo. Le marqueur « Aperçu » signale le JPEG embarqué, trop petit pour juger la netteté : le rendu RAW le remplace dès qu'il est prêt.

A zoome sur la position AF que le boîtier Sony a écrite dans le fichier (repère : un petit cercle) ; tant que ce zoom reste actif, chaque photo s'ouvre sur sa propre position AF, au même grossissement. C'est l'endroit visé par l'autofocus, pas une garantie de netteté. Sans position enregistrée, le zoom se fait au centre et le dit.

## Développement

```sh
xcodegen generate
xcodebuild test -scheme BetterView -destination 'platform=macOS'
```

Mesures sur de vrais fichiers, sans jamais toucher au dossier (build Release) :

```sh
BetterView.app/Contents/MacOS/BetterView --bench <dossier>
BetterView.app/Contents/MacOS/BetterView --verify-previews <dossier>
BetterView.app/Contents/MacOS/BetterView --verify-af <dossier>
```

Architecture, décisions et résultats mesurés : [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
