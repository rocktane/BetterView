# BetterView

Visionneuse RAW pour macOS, faite pour trier des photos le plus vite possible.

- Passage d'une photo à l'autre en moins d'une milliseconde quand la photo est préparée.
- Suppression en une touche, vers la corbeille, annulable avec ⌘Z ; historique des suppressions du dossier avec aperçu (⌘Y).
- Une fenêtre qui prend la forme de chaque photo, sans bordure ni barre de titre : on ne voit que la photo.
- Au survol de la photo : boutons de fenêtre, nom, EXIF (ISO, vitesse, ouverture, focale), date et position dans le dossier.
- Une pellicule flottante (le *filmstrip* de Lightroom), détachée de la fenêtre avec détection des rafales.
- Un clic droit sur la photo ou une vignette pour l'envoyer dans Lightroom ou l'app choisie dans les réglages.
- Aucune dépendance, aucun catalogue : un dossier, des photos.

## Installation

Il faut macOS 14 ou plus récent, Xcode et `xcodegen` (`brew install xcodegen`). Le projet Xcode n'est pas versionné : il est généré depuis `project.yml`.

```sh
scripts/install.sh
```

L'app est copiée dans `/Applications`. Pour en faire l'app par défaut des RAW : Réglages (⌘,) > Général.

## Sélection

Comme dans le Finder : ⇧→ et ⇧← étendent ou réduisent la sélection, S (comme ⌘+clic dans la pellicule) ajoute ou retire la photo affichée, et Échap la vide. Avec plusieurs photos sélectionnées, ⌫ les met toutes à la corbeille, après confirmation (désactivable dans Réglages > Général) ; ⌘Z remet le groupe d'un coup.

## Pellicule et comparaison

La pellicule montre les photos du dossier, la photo courante au milieu ; clic pour afficher, Maj+clic et ⌘+clic pour sélectionner comme dans le Finder (pastille ✓ bleue). Elle se déplace en la glissant, s'élargit ou s'agrandit en tirant ses bords, s'aimante au Dock, à l'écran et à la fenêtre, et garde sa taille d'un lancement à l'autre (Réglages > Général > Taille de la pellicule). Les rafales sont entourées.

`C` compare, dans cet ordre : les photos sélectionnées, la rafale de la photo courante (prises à 2 s d'écart au plus), ou la photo courante et la suivante. Le tri se fait à la souris, sur la photo survolée : « Corbeille » la retire, « Garder celle-ci » met les autres photos affichées à la corbeille ; ⌘Z annule le geste d'un coup. Quand il n'en reste qu'une, retour à la vue normale. Z zoome à 100 % au même endroit sur toutes les photos, A chacune sur son point AF ; glisser, défiler ou pincer déplace ensuite tout le groupe.

Une photo protégée porte un cadenas et refuse la suppression. Le marqueur « Aperçu » signale le JPEG embarqué, remplacé par le rendu RAW dès qu'il est prêt.

## Développement

```sh
xcodegen generate
xcodebuild test -scheme BetterView -destination 'platform=macOS'
```

Mesures sur de vrais fichiers, sans jamais toucher au dossier (build Release) : `BetterView.app/Contents/MacOS/BetterView --bench|--verify-previews|--verify-af <dossier>`.

L'icône : `Resources/AppIcon.svg` (+ variantes 16 et 32 px) ; `scripts/make-icon.sh` génère l'asset catalog (`brew install librsvg`).

Architecture, décisions et résultats mesurés : [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Site web

Présentation Astro et démo interactive : [website/README.md](website/README.md). Lancement avec `pnpm --dir website dev`.

## Aperçu d’amélioration auto

Au survol, la carte « Amélioration auto » sous les informations propose un aperçu temporaire du développement RAW. Une fois prêt, glisser la ligne verticale compare l’original à gauche et Auto à droite, avec un zoom et un déplacement synchronisés. Espace bascule entre l’original et Auto en plein cadre ; cliquer à nouveau sur « Amélioration auto » revient au séparateur sans recalcul. L’aperçu disparaît au changement de photo, sans enregistrer ni modifier le fichier. Sa résolution reste limitée à 2 560 pixels de côté, même en zoom.

## Licence

Le code original de BetterView et du site est sous **GNU GPL version 3 uniquement** (`GPL-3.0-only`), voir [LICENSE](LICENSE). Les dépendances, photographies, polices et autres contenus tiers conservent leurs licences propres. L’icône générée par IA ne fait pas l’objet d’une garantie de droits exclusifs.
