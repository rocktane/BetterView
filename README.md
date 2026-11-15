# BetterView

Visionneuse RAW pour macOS, faite pour trier des photos le plus vite possible.

- Passage d'une photo à l'autre en moins d'une milliseconde quand la photo est préparée.
- Suppression en une touche, vers la corbeille, annulable avec ⌘Z ; historique des suppressions du dossier avec aperçu (⌘Y).
- Une fenêtre qui prend la forme de chaque photo, sans bordure ni barre de titre : on ne voit que la photo.
- Au survol de la photo : boutons de fenêtre, nom, puis ISO, vitesse, ouverture et focale, puis date de prise de vue, et position dans le dossier.
- Une pellicule flottante (le *filmstrip* de Lightroom), détachée de la fenêtre avec détection des rafales.
- Une vue Comparer pour garder la meilleure de plusieurs photos : jusqu'à 4 côte à côte, zoom à 100 % synchronisé, et corbeille directement depuis cette vue.
- Un clic droit sur la photo ou une vignette pour l'envoyer dans l'application de son choix.
- Aucune dépendance, aucun catalogue : un dossier, des photos.

## Installation

Il faut macOS 14 ou plus récent, Xcode et `xcodegen` (`brew install xcodegen`). Le projet Xcode n'est pas versionné : il est généré depuis `project.yml`.

```sh
scripts/install.sh
```

L'app est copiée dans `/Applications`. Pour en faire l'app par défaut des RAW : Réglages (⌘,) > Général.

## Sélection

On sélectionne au clavier comme dans le Finder : ⇧→ et ⇧← étendent ou réduisent la sélection, S ou Espace (comme ⌘+clic dans la pellicule) ajoute ou retire la photo affichée, et Échap la vide. Changer de photo sans Maj la garde.

Avec au moins deux photos sélectionnées, ⌫ les met toutes à la corbeille, après confirmation (désactivable dans Réglages > Général) ; ⌘Z remet tout le groupe d'un coup.

## Pellicule et comparaison

La pellicule montre les photos du dossier, la photo courante au milieu. Défilement à deux doigts ou molette sans changer de photo, clic pour afficher ; Maj+clic et ⌘+clic sélectionnent comme dans le Finder (pastille ✓ bleue). Elle se déplace en la glissant, s'élargit ou s'agrandit en tirant ses bords, s'aimante au Dock, à l'écran et à la fenêtre, et garde sa taille d'un lancement à l'autre (Réglages > Général > Taille de la pellicule). Les rafales sont entourées, avec leur nombre de photos au survol.

`C` compare, dans cet ordre : les photos sélectionnées, la rafale de la photo courante (prises à 2 s d'écart au plus), ou la photo courante et la suivante. Le tri se fait à la souris, sur la photo survolée : « Corbeille » la retire, « Garder celle-ci » met les autres photos affichées à la corbeille ; ⌘Z annule le geste d'un coup. Quand il n'en reste qu'une, retour à la vue normale. Z zoome à 100 % au même endroit sur toutes les photos, A chacune sur son point AF ; glisser, défiler ou pincer déplace ensuite tout le groupe.

Changer de photo revient à l'ajusté, sauf avec « Conserver le zoom en changeant de photo » (Réglages > Général). Une touche maintenue ne répète que la navigation et le zoom : une touche de suppression ne supprime qu'une photo. Une photo protégée porte un cadenas et refuse la suppression. Le marqueur « Aperçu » signale le JPEG embarqué, remplacé par le rendu RAW dès qu'il est prêt.

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

L'icône se dessine dans `Resources/AppIcon.svg`, avec deux dessins simplifiés pour les petites tailles : `Resources/AppIcon-32.svg` (32 px) et `Resources/AppIcon-16.svg` (16 px). `scripts/make-icon.sh` en tire toutes les tailles de l'asset catalog (il faut `rsvg-convert` : `brew install librsvg`).

Architecture, décisions et résultats mesurés : [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
