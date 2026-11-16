# BetterView — site

Site statique Astro, avec pnpm. Aucune publication automatique.

```sh
cd website
pnpm install
pnpm dev
```

- `/` : présentation de l’app et simulation interactive sur huit photos WebP distinctes, dont quatre portraits.
- `pnpm build` : sortie statique dans `dist/`.
- `pnpm test` : tests du modèle de sélection, comparaison, suppression et restauration.

La démo reproduit les raccourcis principaux, la sélection par plage ou ⌘/Ctrl-clic, les rafales, la comparaison (quatre vues à la fois), le tri, la protection, l’annulation et l’historique, le zoom et le déplacement synchronisés, les informations au survol, le plein écran, ainsi que le défilement de la pellicule.

Les fichiers et EXIF sont illustratifs. Le zoom 100 % simule un grossissement, pas la résolution d’un RAW. La démo ne mesure pas les performances de l’application native et ne lance ni Finder ni Lightroom. Les modifications sont limitées à la session et le bouton Recommencer les réinitialise.

Photographies d’illustration : huit photos Unsplash, servies localement depuis `public/images/`. Les URLs des originaux et des pages de provenance sont consignées dans `photo-sources.json`.

| Asset        | Provenance                                                                                                                                         |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `mountain`   | [photo-1464822759023-fed622ff2c3b](https://images.unsplash.com/photo-1464822759023-fed622ff2c3b)                                                   |
| `coast`      | [photo-1473116763249-2faaef81ccda](https://images.unsplash.com/photo-1473116763249-2faaef81ccda)                                                   |
| `forest`     | [photo-1448375240586-882707db888b](https://images.unsplash.com/photo-1448375240586-882707db888b)                                                   |
| `lake`       | [photo-1470770841072-f978cf4d019e](https://images.unsplash.com/photo-1470770841072-f978cf4d019e)                                                   |
| `portrait-1` | [pine-forest-on-a-hill-under-a-cloudy-blue-sky-6mxdOYUpnN0](https://unsplash.com/photos/pine-forest-on-a-hill-under-a-cloudy-blue-sky-6mxdOYUpnN0) |
| `portrait-2` | [landscape-photo-of-mountain-Lu2SWEyuLkU](https://unsplash.com/photos/landscape-photo-of-mountain-Lu2SWEyuLkU)                                     |
| `portrait-3` | [a-view-of-a-mountain-through-some-trees-o9jGHeDzULg](https://unsplash.com/photos/a-view-of-a-mountain-through-some-trees-o9jGHeDzULg)             |
| `portrait-4` | [misty-mountain-forest-with-a-winding-road-cEjAmTnarso](https://unsplash.com/photos/misty-mountain-forest-with-a-winding-road-cEjAmTnarso)         |

Icône issue des ressources de BetterView.

Images : miniatures de 240 px et aperçus responsifs de 320, 640, 960 et 1400 px chargés paresseusement. Les fichiers haute résolution (jusqu’à 4000 × 6000 px, WebP qualité 92) ne sont chargés que lors du zoom. Sources : `photo-sources.json`. Pincement du trackpad (Ctrl + wheel et gestes Safari) et déplacement borné aux dimensions réelles de chaque photo.

## Hébergement sous un chemin

La base vaut `/` par défaut. Pour héberger le build sous `/BetterView/` :

```sh
ASTRO_BASE_PATH=/BetterView/ pnpm build
```

Les pages Astro utilisent `import.meta.env.BASE_URL` pour les liens et ressources locales. La visionneuse reçoit cette même base via `data-base` pour résoudre les chemins des photos côté client. Sans JavaScript, une photo et un message explicatif restent accessibles dans le HTML initial.

## Contrat de la visionneuse

`Viewer.astro` conserve `data-viewer`, `data-interactive`, `data-comparison`, `data-stage`, `data-film`, `data-thumbnails`, `data-toast`, `data-history`, `data-history-list`, `data-close` et `data-action`. `data-announcement` est une région live polie réservée aux annonces de navigation. Le dialogue est nommé par un titre d’identifiant unique.

Les vignettes suivent `.thumb > .thumb-photo + .selection-toggle` : deux boutons frères, états `.current` et `.selected` sur le wrapper, `.check` facultatif dans le bouton de sélection. Le CSS conserve la hauteur des images et leur largeur naturelle ; le bouton de sélection offre une cible de 32 px sur desktop et 44 px en tactile ou sous 650 px.

Le JavaScript calcule les dimensions de scène et des images. En comparaison tactile ou sous 650 px, chaque cellule réserve 88 px en bas pour deux actions de 44 px ; la surface photographique utile exclut cette barre. La grille conserve deux colonnes et deux rangées au-delà de deux vues. Le calcul JS doit dimensionner la scène selon les ratios des photos et ajouter cette réserve aux cellules concernées, y compris en plein écran.

## Vérification reproductible

`pnpm test` exécute les 18 tests purs du modèle et de la géométrie.
La suite navigateur utilise Playwright Chromium, installé une fois avec
`pnpm exec playwright install chromium`. Elle démarre et arrête elle-même
Astro preview sur le port 4397, qui doit être libre :

```sh
pnpm build
pnpm test:browser
ASTRO_BASE_PATH=/BetterView/ pnpm build
ASTRO_BASE_PATH=/BetterView/ pnpm test:browser
pnpm build # remettre dist dans son état racine habituel
pnpm format:check
```

Les 11 scénarios navigateur couvrent les sélections disjointes et plages,
les coches au clavier, les annonces, la suppression et restauration en
comparaison, Espace et A, les ratios et resize, les actions tactiles à 320 px,
les limites du pan et les gestes synthétiques, les nœuds persistants,
les aperçus responsifs, les erreurs d’images, les requêtes HD réservées au
zoom, le plein écran, la base de chemin et le repli sans JavaScript.
`pnpm format` reformate les sources avec Prettier et son parseur Astro ;
aucun lint supplémentaire n’est imposé.

Ces tests sont automatisés sous Chromium desktop et en émulation tactile.
Ils ne valident ni appareil tactile, ni trackpad physique, ni Safari réel,
ni VoiceOver/NVDA, ni les performances mémoire ou en réseau limité.
Les gestes Safari sont des événements synthétiques. Les images HD ne sont
retenues par le code que pendant leur décodage ; le cache et les buffers du
navigateur restent sous son contrôle. Voir `REVIEW-FOLLOWUP.md` pour les 23
points de la revue et leur preuve. Le lien Installer est conservé à la
demande de Yohan, la release étant attendue.

## Mesure d’audience

Umami est auto-hébergé sur ibox : https://stats.yohan.one. Le site « BetterView »
porte l’identifiant `3e82cbfe-f982-4832-8fec-dbc22cbf965a`. Le composant commun
`src/components/Analytics.astro` couvre toutes les pages, sans cookies, avec
respect de Do Not Track et exclusion des query strings et fragments.

Le domaine autorisé par défaut est `betterview.photos`. Pour le remplacer,
définir `PUBLIC_UMAMI_DOMAINS` au build (sans protocole ni chemin, plusieurs
domaines séparés par des virgules). Une valeur vide désactive le script. Le serveur de développement ne charge jamais
le script ; les builds de prévisualisation ne sont pas comptés hors des domaines
autorisés. Build habituel : `pnpm build`. Désactivation : `PUBLIC_UMAMI_DOMAINS= pnpm build`.

## Licence

Le code original de BetterView et du site est sous **GNU GPL version 3 uniquement** (`GPL-3.0-only`), voir [LICENSE](../LICENSE). Les dépendances, photographies, polices et autres contenus tiers conservent leurs licences propres. L’icône générée par IA ne fait pas l’objet d’une garantie de droits exclusifs.
