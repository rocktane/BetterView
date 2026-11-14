# BetterView

Visionneuse RAW pour macOS, faite pour trier des photos Sony A7C le plus vite possible.

- Passage d'une photo à l'autre en moins d'une milliseconde quand la photo est préparée.
- Suppression en une touche, vers la corbeille, annulable avec ⌘Z ; historique des suppressions du dossier avec aperçu (⌘Y).
- Une fenêtre qui prend la forme de chaque photo, sans bordure ni barre de titre : on ne voit que la photo. Elle se déplace en glissant la photo. Le bouton vert (ou ⌃⌘F) passe en plein écran : la bande en bas sur toute la largeur, la photo ajustée au-dessus.
- Au survol de la photo : boutons de fenêtre, nom, puis ISO, vitesse, ouverture et focale, puis date de prise de vue, et position dans le dossier. Rien quand le pointeur est ailleurs. Informations masquées (I, ou Réglages > Général) : un petit « i » en bas à gauche, au survol, les réaffiche d'un clic.
- Une bande d'aperçu flottante, détachée de la fenêtre : les photos d'avant et d'après, et les rafales repérées. Elle se déplace en la glissant, s'aimante au Dock, au centre de l'écran et à la fenêtre de la photo, et s'agrandit en tirant ses bords.
- Une vue Comparer pour garder la meilleure de plusieurs photos : jusqu'à 4 côte à côte, zoom à 100 % synchronisé, et corbeille directement depuis cette vue.
- Un clic droit sur la photo ou une vignette pour l'envoyer dans Lightroom, avec la sélection ou tout le dossier.
- Aucune dépendance, aucun catalogue : un dossier, des photos.

## Installation

Il faut macOS 14 ou plus récent, Xcode et `xcodegen` (`brew install xcodegen`). Le projet Xcode n'est pas versionné : il est généré depuis `project.yml`.

```sh
scripts/install.sh
```

L'app est copiée dans `/Applications`. Pour en faire l'app par défaut des RAW : Réglages (⌘,) > Général.

## Raccourcis

Ils se changent dans Réglages (⌘,) > Raccourcis : clic sur une touche pour la changer, + pour en ajouter une, survol puis × pour la retirer, ↺ pour rétablir une action. Une touche déjà prise est signalée, avec Remplacer ou Annuler. Valeurs par défaut :

| Touche | Action |
|---|---|
| ← → (ou ↑ ↓), Espace | Précédente, suivante |
| Page préc., Page suiv. | Reculer, avancer de 10 photos |
| Début, Fin | Première, dernière photo |
| ⇧→ ⇧← (ou ⇧↓ ⇧↑) | Étendre la sélection à la photo suivante, précédente |
| S | Sélectionner ou désélectionner la photo |
| ⌫, ⌦, X ou ⌘⌫ | Mettre à la corbeille la photo, ou les photos sélectionnées, puis afficher la suivante |
| ⌘Z | Annuler la suppression |
| Z | 100 % ou ajusté |
| A | 100 % sur le point AF enregistré, ou ajusté (dans la comparaison : chaque photo sur le sien) |
| ⌘+ (ou ⌘=), ⌘− | Zoom avant, arrière : 25, 50, 100, 200, 400, 800 % |
| ⌘0 (ou ⌘à en AZERTY) | Ajuster à la fenêtre |
| I | Afficher ou masquer les informations (aussi dans Réglages > Général et le menu Présentation, coché quand elles sont affichées) |
| R | Afficher dans le Finder |
| Échap | Vider la sélection et quitter le zoom, puis la comparaison, puis le plein écran |
| B | Afficher ou masquer la bande d'aperçu |
| C | Comparer les photos, ou quitter la comparaison |

Non modifiables : clic (100 % ou ajusté, à l'endroit cliqué ; un double-clic compte pour un seul clic), pincement, défilement et glisser (zoom, déplacement), ⌘O, ⌘, ⌘W, ⌘Q, et ⌘Y (suppressions du dossier : aperçu et restauration d'une photo précise, sans annuler les suivantes).

## Sélection

On sélectionne au clavier comme dans le Finder. ⇧→ passe à la photo suivante et la sélectionne avec celle qu'on quitte ; en revenant avec ⇧←, la sélection se réduit au lieu de grandir. S, comme ⌘+clic dans la bande, ajoute ou retire la photo affichée, et la prochaine série ⇧→ part de là. Changer de photo sans Maj garde la sélection, et Échap la vide.

Quand au moins deux photos sont sélectionnées, ⌫ les met toutes à la corbeille, après confirmation (on peut cocher « Ne plus demander », ou décocher l'option dans Réglages > Général). Avec une seule photo sélectionnée, ⌫ supprime la photo affichée, comme d'habitude. Les photos protégées restent dans le dossier, et ⌘Z remet tout le groupe d'un coup.

## Bande d'aperçu et comparaison

La bande est une pellicule : chaque vignette a la forme de sa photo, la photo courante reste au milieu, et la bande cesse de défiler aux extrémités du dossier pour rester remplie. Défilement à deux doigts ou molette : parcourir la bande sans changer de photo ; elle revient sur la photo courante dès qu'on change de photo. Clic : aller à cette photo. Comme dans le Finder, Maj+clic sélectionne toutes les photos jusqu'à celle-ci, et ⌘+clic ajoute ou retire une seule photo, sans changer la photo affichée. Les photos sélectionnées portent une pastille ✓ bleue. Dès qu'une photo est cochée, chaque vignette montre un rond vide au même endroit : un clic sur le rond coche ou décoche la photo, un clic ailleurs l'affiche. Les ronds disparaissent quand plus rien n'est coché. Glisser, y compris depuis une vignette : déplacer la bande. Tirer un de ses bords (le curseur change) : l'élargir pour voir plus de photos, ou la grandir pour des vignettes plus grandes ; un coin fait les deux. Une bande centrée reste centrée, une bande collée au Dock ou à la fenêtre y reste, et sa taille est gardée d'un lancement à l'autre. Réglages > Général > Taille de la bande propose Petite, Normale et Grande ; étirer la bande passe sur Personnalisée. Cette taille est un maximum : un dossier de quelques photos donne une bande juste assez large pour elles. Lâchée près du bord bas de la fenêtre de la photo, la bande s'accroche dessous, au centre si on l'en approche, puis suit la fenêtre quand on la déplace ou qu'elle change de forme ; s'en éloigner la décroche. Les rafales sont entourées ; au survol, une bulle donne leur nombre de photos. L'opacité des autres vignettes se règle dans Réglages (⌘,) > Général. La bande reste affichée pendant un zoom. Elle reste affichée tant que BetterView est l'app active, réglages ou historique ouverts compris, et se masque quand on passe à une autre app.

`C` compare, dans cet ordre de préférence : les photos sélectionnées, la rafale de la photo courante (photos consécutives prises à 2 s d'écart au plus), ou la photo courante et la suivante.

La comparaison se trie à la souris uniquement : rien ne se sélectionne au clic ni au clavier. Les boutons « Corbeille » et « Garder celle-ci » apparaissent sur la photo survolée et agissent sur elle. « Corbeille » la retire, et la photo suivante du groupe prend sa place sans que les autres bougent. « Garder celle-ci » met à la corbeille les autres photos affichées, jamais celles encore en attente. ⌫, les flèches et les chiffres n'y font rien ; ⌘Z annule tout le geste d'un coup. Double-cliquer zoome à l'endroit cliqué, et glisser déplace la fenêtre, ou les photos une fois zoomé. Quand il ne reste qu'une photo, on revient à la vue normale, sur la dernière photo gardée ou touchée, où ⌘Z reste possible. R (ou Fichier > Afficher dans le Finder, actif seulement quand une photo est survolée) affiche dans le Finder la photo survolée.

Dans la comparaison, Z zoome à 100 % au même endroit sur toutes les photos. A les zoome à 100 % chacune sur son propre point AF, avec le petit cercle ; glisser, défiler ou pincer déplace ensuite toutes les photos du même écart. Quand une nouvelle photo entre (suppression, « Garder celle-ci », annulation), la comparaison revient à l'ajusté ; avec « Conserver le zoom en changeant de photo », elle s'ouvre au contraire sur son point AF avec l'écart commun. Une photo sans point AF, ou en mise au point manuelle, est centrée au milieu et le dit. A une seconde fois, Z ou Échap reviennent à l'ajusté.

Les lettres suivent la disposition du clavier (AZERTY compris). Maintenir une touche ne répète que la navigation et le zoom : maintenir une touche de suppression ne supprime qu'une seule photo, quelle que soit la touche choisie. Une photo protégée dans le boîtier ou verrouillée dans le Finder (ou sans droit d'écriture) porte un petit cadenas : la suppression la refuse aussitôt avec un bref bandeau, aussi dans la comparaison, et BetterView ne retire jamais cette protection. La suppression définitive n'est proposée que sur un volume sans corbeille, avec confirmation à chaque fois. Le marqueur « Aperçu » signale le JPEG embarqué, trop petit pour juger la netteté : le rendu RAW le remplace dès qu'il est prêt.

Un clic zoome à 100 % à l'endroit cliqué, un autre revient à l'ajustement ; glisser déplace alors l'image. Pendant un zoom, son niveau s'affiche en haut à droite de la photo. Changer de photo (navigation, saut, clic dans la bande, suppression) revient à l'ajusté, et la fenêtre reprend la forme de la nouvelle photo. Réglages > Général > « Conserver le zoom en changeant de photo » garde au contraire le zoom et sa position d'une photo à l'autre.

A zoome sur la position AF que le boîtier Sony a écrite dans le fichier (repère : un petit cercle). Changer de photo revient à l'ajusté ; avec « Conserver le zoom en changeant de photo », chaque photo s'ouvre au contraire sur sa propre position AF, au même grossissement. C'est l'endroit visé par l'autofocus, pas une garantie de netteté. Sans position enregistrée, le zoom se fait au centre et le dit.

## Menu contextuel

Clic droit (ou ⌃+clic) sur la photo ou sur une vignette de la bande. Comme dans le Finder, le menu agit sur toute la sélection quand la photo cliquée en fait partie, sinon sur cette photo seule.

- Ouvrir dans Lightroom Classic (ou Lightroom) : la photo ou la sélection, et, en plus, les photos sélectionnées et toutes les photos du dossier quand elles sont plus nombreuses. Une confirmation est toujours demandée, même pour une photo. Lightroom Classic montre ensuite sa fenêtre d'importation : rien n'entre dans le catalogue avant d'y cliquer sur Importer.
- Ouvrir avec : les autres apps qui ouvrent ce format, celle par défaut en premier.
- Afficher dans le Finder, Copier (les fichiers, à coller dans le Finder ou une autre app), Partager.
- Sélectionner ou désélectionner la photo, Tout désélectionner, Comparer les photos visées.
- Mettre à la corbeille, annulable avec ⌘Z. Une photo qui n'est pas celle affichée demande confirmation, comme une sélection.

Le menu n'est pas proposé dans la comparaison.

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
