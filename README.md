# BetterView

Visionneuse RAW pour macOS, faite pour trier des photos le plus vite possible.

- Passage d'une photo à l'autre en moins d'une milliseconde quand la photo est préparée.
- Suppression en une touche, vers la corbeille, annulable avec ⌘Z ; historique des suppressions du dossier avec aperçu (⌘Y).
- Une fenêtre qui prend la forme de chaque photo, sans bordure ni barre de titre : on ne voit que la photo.
- Au survol de la photo : boutons de fenêtre, nom, EXIF (ISO, vitesse, ouverture, focale), date et position dans le dossier.
- Une pellicule flottante (le *filmstrip* de Lightroom), détachée de la fenêtre avec détection des rafales.
- Un clic droit sur la photo ou une vignette pour l'envoyer dans Lightroom ou l'app choisie dans les réglages.
- Aucun catalogue : un dossier, des photos. Mises à jour intégrées avec Sparkle.

## Installation

Il faut macOS 14 ou plus récent, sur Mac Intel ou Apple Silicon.

La distribution Homebrew est préparée dans [docs/HOMEBREW.md](docs/HOMEBREW.md) et sera disponible après la première release universelle.

Télécharger le ZIP depuis les [releases GitHub](https://github.com/rocktane/BetterView/releases/latest), le décompresser et déplacer BetterView dans `/Applications`.

L'app n'a pas de certificat Apple et n'est pas notarisée. Au premier lancement, macOS peut refuser de l'ouvrir : après cette tentative, aller dans **Réglages Système > Confidentialité et sécurité > Ouvrir quand même**, puis confirmer.

Si macOS indique que l'app est endommagée et ne propose pas cette option, après avoir vérifié que le ZIP provient bien des releases de ce dépôt, retirer uniquement la quarantaine de BetterView depuis Terminal :

```sh
xattr -dr com.apple.quarantine /Applications/BetterView.app
```

Les mises à jour suivantes sont proposées dans l'app par Sparkle. Le menu **BetterView > Rechercher les mises à jour…** permet aussi de vérifier manuellement. Sparkle demande l'autorisation d'activer les vérifications automatiques. Les archives sont authentifiées par une signature Sparkle Ed25519, indépendante d'un certificat Apple.

### Construire depuis les sources

Il faut Xcode et `xcodegen` (`brew install xcodegen`). Le projet Xcode n'est pas versionné : il est généré depuis `project.yml`. Sparkle est téléchargé automatiquement via Swift Package Manager.

```sh
scripts/install.sh
```

L'app est copiée dans `/Applications`. Pour en faire l'app par défaut des RAW : Réglages (⌘,) > Général.

## Sélection

Comme dans le Finder : ⇧→ et ⇧← étendent ou réduisent la sélection, S ou Espace (comme ⌘+clic dans la pellicule) ajoute ou retire la photo affichée, et Échap la vide. Avec plusieurs photos sélectionnées, ⌫ les met toutes à la corbeille, après confirmation (désactivable dans Réglages > Général) ; ⌘Z remet le groupe d'un coup.

## Pellicule et comparaison

La pellicule montre les photos du dossier, la photo courante au milieu ; clic pour afficher, Maj+clic et ⌘+clic pour sélectionner comme dans le Finder (pastille ✓ bleue). Elle se déplace en la glissant, s'élargit ou s'agrandit en tirant ses bords, s'aimante au Dock, à l'écran et à la fenêtre, et garde sa taille d'un lancement à l'autre (Réglages > Général > Taille de la pellicule). Les rafales sont entourées.

`C` compare, dans cet ordre : les photos sélectionnées, la rafale de la photo courante (prises à 2 s d'écart au plus), ou la photo courante et la suivante. Le tri se fait à la souris, sur la photo survolée : « Corbeille » la retire, « Garder celle-ci » met les autres photos affichées à la corbeille ; ⌘Z annule le geste d'un coup. Quand il n'en reste qu'une, retour à la vue normale. Z zoome à 100 % au même endroit sur toutes les photos, A chacune sur son point AF ; glisser, défiler ou pincer déplace ensuite tout le groupe.

Une photo protégée porte un cadenas et refuse la suppression. Le marqueur « Aperçu » signale le JPEG embarqué, remplacé par le rendu RAW dès qu'il est prêt.

La procédure de publication et la gestion de la clé Sparkle sont décrites dans [docs/RELEASING.md](docs/RELEASING.md).

## Développement

```sh
xcodegen generate
xcodebuild test -scheme BetterView -destination 'platform=macOS'
```

Mesures sur de vrais fichiers, sans jamais toucher au dossier (build Release) : `BetterView.app/Contents/MacOS/BetterView --bench|--verify-previews|--verify-af <dossier>`.

L'icône : `Resources/AppIcon.svg` (+ variantes 16 et 32 px) ; `scripts/make-icon.sh` génère l'asset catalog (`brew install librsvg`).

Architecture, décisions et résultats mesurés : [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
