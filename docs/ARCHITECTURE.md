# BetterView: architecture (v3)

Visionneuse RAW macOS native, mono-usage : trier des photos Sony A7C le plus vite possible.

## 1. Besoin

- Ouvrir un ARW (double-clic Finder) ou un dossier, passer d'une photo à l'autre sans latence perceptible.
- Supprimer en une touche.
- Réglages : devenir l'app par défaut pour les formats RAW courants, raccourcis configurables.
- Bande d'aperçu et comparaison de photos proches, pour garder la meilleure.
- Hors périmètre : édition, catalogue, notation, métadonnées avancées, export, sync, sandbox, Mac App Store.
- Utilisateur unique, usage personnel. Machine : M1 Pro 8 cœurs, 16 Go, écran 3024×1964, macOS 27.

## 2. Mesures réelles (24 Mpx A7C, ARW compressés 25 Mo, SSD interne, cache de pages chaud)

Pixels forcés en mémoire. Médianes sauf mention.

| Opération | Temps | Résultat |
|---|---|---|
| Lecture en-tête | 4,7 ms | |
| Aperçu JPEG embarqué (ImageIO) | 28 ms | 1616×1080 seulement (pas de JPEG pleine taille dans ces ARW) |
| Aperçu embarqué, 4 workers, pixels forcés, n=100, 2 passes | 125 images/s, latence p50 32 ms, p99 36 ms | Voie fast dimensionnée sur cette mesure |
| CIRAWFilter → IOSurface, adapté écran (scale 0,49) | 267 ms | 2940×1960, 23 Mo BGRA |
| CIRAWFilter → IOSurface, pleine résolution | 329 ms | 6000×4000, 96 Mo BGRA |
| ImageIO décodage complet | 513 ms | Rejeté, plus lent et CPU |
| ImageIO « from-full » max 3840 | 755 ms | Rejeté |
| CIRAW workers 1/2/3/4 | 303/254/229/145 ms/image | Mesure bruitée, ordre fixe, à reconfirmer en M0 |
| CIRAW workers 8 | environ 212 ms/image, RSS 2,1 Go | Rejeté (sans autoreleasepool) |
| Cache disque JPEG q90 de la frame écran | écriture 27 ms, lecture+décodage 25 ms, 0,9 Mo | Retenu |
| Cache disque HEIC q90 | écriture 131 ms, lecture 75 ms, 0,5 Mo | Rejeté |
| Cache disque BGRA brut | écriture 8 ms, lecture 3,7 ms, 23 Mo | Rejeté (usure et place : 26× plus gros pour 20 ms invisibles en préchargement) |

Le premier décodage du processus coûte plus cher (pic à 230 ms, initialisation). Non mesuré : commit CALayer et présentation effective, latence au premier plan sous charge, lecture à froid, carte SD, volume SMB. Voir M0. Les objectifs de la section 7 restent provisoires jusque-là.

Conclusions :
1. L'aperçu embarqué est un substitut de 28 ms, mais trop petit pour juger la netteté.
2. Un rendu RAW coûte environ 270 ms : indispensable de le faire **avant** que l'utilisateur arrive sur la photo.
3. Cache disque JPEG : 10× plus rapide que le rendu, et de qualité écran.
4. Afficher une frame décodée déjà en mémoire ne coûte que le commit Core Animation.

## 3. Principes

1. **État sur le main thread, sans verrou.** Listes, caches, file d'attente vivent sur `@MainActor`. Les workers sont des fonctions pures `entrée → Frame`.
2. **La navigation ne bloque jamais.** Elle fait uniquement un lookup O(1) puis un commit de layer.
3. **Un seul pipeline RAW** : CIRAWFilter → IOSurface, pour l'écran comme pour le zoom.
4. **Jamais de pixels périmés** : la vue n'affiche que des frames dont la clé est égale à `PhotoKey` de la photo courante, ou rien. La touche Supprimer n'agit que si la photo courante est visible (frame affichée, ou écran d'erreur portant son nom) ; sinon elle est ignorée.
5. **Identité = révision** : une photo est identifiée par `PhotoKey` (URL + identifiant de fichier + taille + mtime), propagée à tous les travaux, caches et opérations destructives.
6. **Aucune E/S sur le main thread.** Scan, tri, stat, index disque, éviction disque se font hors main ; le main ne reçoit que des instantanés versionnés.
7. **Pas de dépendance.** AppKit, Core Animation, Core Image, ImageIO. SwiftUI seulement pour la fenêtre de réglages.

## 4. Niveaux d'image

| Tier | Source | Taille | Coût | Rôle |
|---|---|---|---|---|
| P | JPEG embarqué | 7 Mo | 28 ms | Substitut immédiat, défilement rapide |
| S | Rendu RAW adapté au plus grand écran | ≤ 23 Mo sur l'écran actuel | 267 ms, ou 25 ms via disque | Affichage normal |
| F | Rendu RAW 100 % | 96 Mo | 329 ms | Zoom |

- S est calculé par image (dans le worker, depuis l'extent orienté de CIRAWFilter) : facteur = min(1, écranL/imageL, écranH/imageH). Une photo portrait ne coûte donc que 10 Mo. Indépendant de la taille de fenêtre, donc pas de re-rendu au redimensionnement ; changement d'écran = nouvelle clé.
- La lecture de P rapporte aussi la position AF enregistrée par le boîtier (voir « Point AF »), sans lecture de plus.
- P affiché est signalé par un petit marqueur discret : ne pas juger la netteté dessus. Le rendu Sony et le rendu Apple diffèrent (couleurs) : un saut visuel P→S est accepté, et rare hors défilement rapide. Pas de fondu, pour ne pas ajouter de latence.
- Formats sans aperçu exploitable : pas de P, passage direct à S. Format non décodable : écran d'erreur avec le nom du fichier, navigation et suppression restent possibles.

## 5. Composants

```
AppDelegate ── ViewerWindowController ── ViewerView (CALayer)
                     │
              ViewerController (@MainActor : logique de navigation, zoom, suppression)
               │        │              │
          PhotoList  Pipeline       TrashService (file série)
               │        │
      FolderScanner   ├─ WindowPlanner (pur : position → travaux désirés)
      FolderWatcher   ├─ FrameCache (LRU par octets, par tier)
                      ├─ DiskCache (JPEG, LRU par octets)
                      └─ Workers : PreviewDecoder, RawRenderer, DiskCodec
Settings : Preferences, FileAssociations, SettingsView (SwiftUI)
```

Environ 1500 lignes. Un dossier source, une cible app, une cible de tests. Projet généré par xcodegen.

### Frame

`final class Frame: @unchecked Sendable`, immuable après création : `surface` (IOSurface pour tous les tiers, voir section 11), `nativeSize`, `byteCost`, `key`. L'objet est passé tel quel à `CALayer.contents`, sans copie pour IOSurface.

### Pipeline, le cœur

Tout l'état est sur le main thread. Il n'y a pas de pool de threads géré à la main : le Pipeline tient des files par voie et lance un bloc GCD seulement si un slot est libre. À la fin du bloc : retour main, insertion cache, notification, `pump()`.

| Voie | Slots | Travaux |
|---|---|---|
| fast | 4 | P, lecture disque S |
| gpu | 3 : le travail spéculatif en occupe au plus 2, le 3e est réservé à la demande visible | rendu S, rendu F |
| encode | 1 | écriture disque, abandonnée au-delà de 4 en attente (≤ 92 Mo retenus) |

À chaque navigation (`navigate(to:direction:)`) :
1. Lookup FrameCache par `PhotoKey` : meilleur tier disponible → affichage synchrone (S ou P). Sinon vide + nom du fichier.
2. `WindowPlanner` produit une liste ordonnée de travaux (≈ 100 éléments), **qui remplace les files en attente**. Les travaux en vol ne sont pas annulables ; leur résultat va au cache sous leur propre clé, ce qui le rend inoffensif s'il est périmé. Un travail en vol déjà désiré n'est pas relancé. Une demande visible peut donc attendre au pire la fin d'un rendu en vol sur le slot réservé (mesuré ≈ 330 ms, ce n'est pas une borne dure) ; P s'affiche entre-temps.
3. `pump()`.

Déduplication par table `inFlight[clé]`. L'existence disque est lue dans un `Set` de clés chargé au lancement, mis à jour à chaque écriture, donc pas de `stat` sur le main thread : on choisit directement entre voie fast et voie gpu.

Ordre WindowPlanner, strict :
1. **demande visible** : P et S du courant, plus F du courant si le zoom est actif (slot réservé) ;
2. S des voisins immédiats ±1 ;
3. P sur ±25 ;
4. S : avant +20, arrière −8 (inversé si direction arrière) ; proches d'abord ;
5. F : courant + voisin suivant, après 500 ms sur la même photo ; si zoom actif, voisins ±1 ;
6. **tâche de fond** (> 2 s sans input, sur secteur, thermique nominal, pression mémoire normale) : parcourt le reste du dossier en mode `render → encode → libérer`. Ces frames ne vont **jamais** en cache RAM, et le parcours se met en pause si la voie encode a plus de 2 travaux en attente. Elle remplit le disque sans étendre le voisinage protégé.

Répétition de touche (`NSEvent.isARepeat`) : seul P est planifié autour du courant, le S courant ne part qu'après 120 ms sur la même photo, pour ne pas saturer les slots GPU de rendus aussitôt périmés. La voie fast (125 images/s mesurées) dépasse la répétition clavier (30 Hz). Le préchargement S reprend au relâchement.

Démarrage : l'affichage du fichier demandé et l'initialisation du `CIContext` partent **en parallèle** hors main ; un travail RAW attend simplement que le contexte soit prêt, ce qui marche aussi pour un fichier sans aperçu. `CIContext` partagé (Metal, `cacheIntermediates: false`, sortie P3). `autoreleasepool` autour de chaque travail.

Le travail P rend aussi la position AF lue dans le même en-tête ; le main la range dans une table `PhotoKey → CameraFocus` (quelques octets par photo) **avant** d'insérer la frame, pour que la vue puisse centrer la photo dès son apparition. Si S est déjà en cache sans que P ait jamais été lu (rare), le planificateur lance à la place de P un travail « en-tête seul » sur la voie fast (64 Kio, pas de décodage).

Validation d'un travail (P et RAW, y compris avant tout encodage disque) : le worker relit la révision (un `stat`) **avant et après** le décodage. Si l'une des deux diffère de la clé du travail, il renvoie `.stale`, ce qui déclenche un rescan, sans résultat ni écriture disque. Le main insère le résultat sous la clé du travail ; il n'affiche que si cette clé est celle de la photo courante, et que la configuration de rendu (dimension cible) est toujours valable.

### FrameCache

Sur `@MainActor`, dictionnaire + liste chaînée LRU, éviction O(1).
Budgets d'octets réels (`IOSurface.allocationSize`, pas largeur × hauteur × 4) : S 1 Go (≈ 43 images), P 400 Mo (≈ 57), F 300 Mo (3). Total 1,7 Go, mis à l'échelle de la RAM physique. Les fenêtres de préchargement (S 29 images soit 670 Mo, P 51 soit 360 Mo) tiennent dans ces budgets : le reste garde les photos récemment vues. Une frame du voisinage protégé (fenêtres ci-dessus) n'est pas évincée au profit d'un travail hors voisinage. Quand S existe, P de cette photo est évinçable en premier.

Pression mémoire (`DispatchSource.makeMemoryPressureSource`), qui agit sur **l'admission autant que sur l'éviction**, en réglant un `memoryLevel` lu par le Planner : warning → tâche de fond arrêtée, spéculatif limité à ±3, F vidé sauf courant ; critical → courant seul, encode vidé. Les résultats en vol hors voisinage sont alors abandonnés à leur arrivée.

### DiskCache

`~/Library/Caches/BetterView/`, JPEG q90 P3, 2 Go par défaut (environ 2 300 images), écriture atomique (temp + rename), LRU par date d'accès. Clé = SHA-256 de `(PhotoKey, version du rendu, version de macOS, dimension cible)`. Index et éviction hors main ; tant que l'index n'est pas chargé, tout est considéré comme absent. Chaque éviction, écriture ou vidage met à jour le `Set` côté main.

**Échec de lecture** (fichier absent, purgé par macOS, JPEG illisible) : la clé est retirée de l'index et S est replanifié en rendu RAW, s'il est toujours désiré. **Vider le cache** (bouton dans les réglages) incrémente une génération : les écritures en attente ou en vol de génération antérieure sont abandonnées. Entrée retirée quand la photo est supprimée. F n'est jamais mis sur disque.

### Affichage

`ViewerView` : NSView layer-hosting, un seul `CALayer` image, `contents` assigné dans une `CATransaction` sans action. `contentsGravity` et géométrie calculés sur les dimensions logiques natives, ce qui permet de permuter P/S/F sans saut de géométrie. Zoom : transformation de layer, F remplace S à son arrivée. Grossissement > 100 % en `nearest`. Le zoom et sa position sont conservés entre photos pour comparer la mise au point. La position demandée est bornée aux bords **pour la mise en page seulement** : P n'a souvent pas la taille de la photo (sur l'A7C, le SubIFD qui la donne est au-delà des 64 Kio lus, P garde donc la taille du JPEG, 1616×1080), et borner la position mémorisée sur cette taille la détruisait avant l'arrivée de S. Seul le déplacement à la main mémorise une position bornée. IOSurface étiquetée en P3 : `IOSurfaceSetValue(surface, kIOSurfaceColorSpace, CGColorSpaceCopyPropertyList(p3))`, vérifiée visuellement en M0.

### Point AF

Commande A : 100 % sur la position AF enregistrée par le boîtier. Le zoom Z (centré sur le curseur) ne change pas.

- **Source.** MakerNote Sony, tag `0x2027` FocusLocation : largeur, hauteur, x, y en 16 bits non signés, en coordonnées capteur (paysage, origine en haut à gauche). Chemin : IFD0 → IFD EXIF (`0x8769`) → MakerNote (`0x927C`). Sur l'A7C, le MakerNote n'a pas d'en-tête et ses offsets comptent depuis le début du fichier ; un en-tête `SONY DSC ` ou `SONY CAM ` (anciens boîtiers) est sauté avec les mêmes offsets ; tout autre en-tête est refusé. Le tag `0x201B` FocusMode (0 = manuel) est lu au passage. Tout est en clair : les blocs chiffrés (`0x2010`, `0x9050`, `0x94xx`) ne servent pas. ImageIO n'expose pas cette valeur. Une valeur hors des 64 Kio déjà lus est traitée comme absente : jamais de lecture en plus.
- **Orientation.** Conversion vers l'image droite : 1 → (x, y) ; 3 → (L − x, H − y) ; 6 → (H − y, x) ; 8 → (y, L − x), puis normalisation. CIRAWFilter rend les ARW de l'A7C en 6000×4000 (ou 4000×6000) orientés, origine 0, sans recadrage : exactement le repère de FocusLocation (`DefaultCropSize` = 6000×4000 dans un capteur de 6048×4024). La position normalisée retombe donc sur le même pixel, quelle que soit l'échelle de la frame affichée.
- **Mode suivi.** A active un mode qui dure tant que le zoom est actif : chaque photo affichée (navigation, suppression, ouverture) est centrée sur sa propre position AF, au grossissement courant, ce qui permet de comparer la netteté d'une rafale au point visé. Déplacer ou pincer ne quitte pas le mode ; la photo suivante se recentre sur son point AF. A une seconde fois, Z, Échap, double-clic ou pincement jusqu'à l'ajusté : retour à l'ajusté et fin du mode. Si la position n'est pas encore lue (photo jamais préparée), la vue se centre provisoirement au milieu, puis se recentre à l'arrivée de l'en-tête (≈ 15-30 ms, avec P), sauf si l'utilisateur a déjà déplacé l'image.
- **Absence.** Pas de position (autre format, tag absent) ou mise au point manuelle : zoom au centre, et une mention dans le badge (« Pas de point AF : centre », « Mise au point manuelle : centre »). Pas de bip : en mode suivi, il sonnerait à chaque photo, et le centre est aussi le repli du boîtier.
- **Repère.** Un cercle fin blanc, 22 pt, avec ombre, affiché seulement dans ce mode. Pas de vert ni de cadre AF : rien ne doit laisser croire que la mise au point y est garantie.
- **Centre exact.** Sur 562 ARW réels, 71 ont exactement (3000, 2000) : 56 en zone AF « Centre » (attendu), 2 en suivi des visages avec la zone « Centre », 13 en « Large », mode où les mêmes valeurs reviennent souvent (x = 1818, 2053, 3000, 3946, 4181 ; y = 1341, 1500, 2000, 2658), comme des positions de collimateurs dont le centre ferait partie. Rien ne montre un repli faute de position : le centre est traité comme une vraie position. Le zoom serait de toute façon identique.
- **Ce que la valeur ne dit pas.** Exemple observé (A7C03320, suivi des visages, 3 visages détectés) : la position enregistrée tombe au-dessus d'une tête, hors des cadres de visage que le boîtier a lui-même enregistrés. La vue montre la valeur du boîtier telle quelle.
**Forme de la fenêtre** (`WindowShape`, `ViewerController.applyWindowShape`) : la fenêtre prend le ratio de la photo, ce qui supprime les bordures sans rien recadrer. Un rendu lui donne toujours sa forme exacte ; un aperçu, dont la taille vient d'un en-tête légèrement différent, ne la change que si le ratio s'écarte de plus de 1 %. Elle ne change pas pendant un zoom, pour comparer la mise au point sans que rien ne bouge. L'image couvre toujours la vue (le plus grand des deux rapports), donc un arrondi ne peut pas ouvrir de bande. Le tier S reste ajusté à l'écran : une photo portrait est affichée à sa pleine définition de rendu.

**Fenêtre seule** : aucun plein écran, natif ou non, et donc aucune touche pour y aller. La barre de titre est invisible. Glisser la photo déplace la fenêtre, sauf en zoom où cela déplace l'image. La fenêtre conserve sa hauteur d'une orientation à l'autre, seule sa largeur change, et les contraintes du bandeau restent sous les priorités de la fenêtre, pour que le texte ne lui impose pas de largeur minimale.

**Survol** : boutons, trois lignes en bas à gauche (nom ; ISO, vitesse, ouverture, focale ; date), position en bas à droite et marqueur « Aperçu » ne s'affichent que si le pointeur est sur la photo. L'état est relu à chaque changement de forme, car une fenêtre qui change sous un pointeur immobile n'envoie aucun événement. Le message d'erreur de décodage reste toujours visible : il porte le nom du fichier qu'une suppression viserait.

**Informations** : `MetadataStore` lit l'EXIF hors main, un fichier à la fois, le plus récent d'abord, et anticipe sur les photos voisines. Pour les `.arw`, lecture directe des 64 premiers Ko (`PhotoMetadata.parse`), sans charger le plugin RAW d'ImageIO ; repli sur ImageIO sinon. Vérifié sur 133 fichiers réels par `--verify-previews` : valeurs identiques à ImageIO. La date reste celle de l'appareil, l'EXIF n'ayant pas de fuseau.



### Bande d'aperçu

La fenêtre change de largeur à chaque photo : la bande vit donc dans son propre `NSPanel` (`StripPanel`), flottant et sans activation. Il ne devient jamais fenêtre clé, donc le clavier reste à la visionneuse, et il se masque quand l'app passe en arrière-plan. La bande disparaît pendant un zoom, pour ne pas couvrir ce qu'on inspecte.

**Aimants** (`StripMagnet`, pur et testé) : le bord du Dock se déduit de l'écart entre `frame` et `visibleFrame` (bas si le Dock est masqué) ; le centre est celui de `visibleFrame`, sur chaque axe indépendamment. La position proposée suit toujours le pointeur : s'éloigner au-delà de la portée (36 pt pour le Dock, 24 pt pour le centre) suffit à décrocher. C'est `StripPlacement` qui est mémorisé, avec les aimants qui retiennent la bande, et non la seule position : une bande retenue suit le Dock et les changements d'écran.

**Vignettes** (`ThumbnailStore`) : 200 px, en priorité basse, sur leur propre file, 2 à la fois, et ce qui attend est remplacé à chaque navigation. Elles ne viennent pas du pipeline : P est évincé dès que S existe, et garder des frames pour la bande retiendrait de la mémoire hors budget. Environ 35 Mo au maximum.

**Mise à jour** : après l'image, au plus une fois par tour de boucle, en affectant des pointeurs à des layers. Chaque vignette a la largeur de sa photo à hauteur fixe ; avant l'arrivée de sa vignette, elle prend du 3:2. Les vignettes sont demandées bien au-delà des bords, donc ce décalage ne se voit qu'en sautant loin. La photo courante reste au milieu, sauf aux extrémités du dossier où la bande s'arrête pour ne pas laisser de vide, et les vignettes coupées par les bords s'estompent.

**Rafales** (`PhotoGroups`) : photos consécutives prises à 2 s d'écart au plus, d'après l'heure EXIF déjà lue par `MetadataStore`. Elles sont cherchées à ±12 photos de la courante, ce qui borne une rafale à 25 photos. Une rafale qui dépasse ce rayon n'est donc vue qu'en partie. Aucune analyse d'image : c'est prévisible, mais deux cadrages proches pris à 10 s d'écart ne sont pas regroupés (Maj+clic couvre ce cas).

### Comparaison

Un mode de la même fenêtre : `ComparisonView` remplace la vue de contenu, la fenêtre prend presque tout l'écran, puis retrouve son cadre exact en sortant. Le nom d'autosave est retiré pendant ce temps, pour que ce grand cadre ne revienne pas au lancement suivant.

`ComparisonModel` (pur, testé) tient 4 emplacements et une file d'attente. Une photo retirée est remplacée sur place par la suivante en attente. À 4 ou 3 photos la grille reste en 2×2 avec une case vide, pour que rien ne bouge ; à 2 elles se partagent l'espace. Quand il n'en reste qu'une, retour à la vue normale, sur cette photo.

**Sécurité** (principe 4) : la suppression n'agit que sur un emplacement qui montre vraiment sa photo. « Garder celle-ci » exige que toutes les photos affichées soient visibles, et ne touche jamais la file d'attente, que personne n'a encore vue. Un fichier modifié sur le disque n'est pas supprimé, comme ailleurs.

**Annulation** : `LibrarySession.trash(_:)` donne le même groupe aux opérations d'un même geste, et ⌘Z restaure tout le groupe. Toute photo retirée qui réapparaît dans la liste (annulation, échec de la corbeille, fichier modifié) retrouve son emplacement dans la comparaison, quel que soit l'ordre d'arrivée. Volume sans corbeille : une alerte par photo, comme pour une suppression seule.

**Pipeline** : `PlanInput.comparison` remplace la fenêtre autour de la photo courante. Toutes les photos affichées sont une demande visible, et leur S est préparé pour les 4 suivantes en attente. En zoom, F de chacune, la photo choisie d'abord. Un seul rendu F à la fois (section 11), soit environ 1,3 s pour 4 photos au premier zoom, pendant lesquelles chaque emplacement affiche S et un marqueur. Le budget F est doublé pendant la comparaison pour que 4 photos tiennent, puis rétabli. Sous pression mémoire, seule la photo choisie reste nette, et les autres emplacements relâchent aussitôt leurs surfaces évincées. Une photo sans aperçu embarqué garde son S déjà rendu ; si elle n'en avait pas encore, l'emplacement affiche son nom, sa suppression reste refusée, et elle se rend dès qu'on la choisit ou que la pression retombe.

### PhotoList et dossier

État main : tableau trié par `localizedStandardCompare` du nom, de `Photo { url, key }`. Extensions acceptées : celles de la section Réglages. Un seul fichier ouvert → affichage **immédiat** avec une liste provisoire `[fichier]`, sans attendre le scan ; plusieurs fichiers sélectionnés → ces fichiers seulement.

`FolderScanner` tourne hors main (énumération, stat, tri) et publie un instantané portant le `sessionID` de la liste et le `opGeneration` lus à son lancement. Il est à exécution unique par session : un seul scan à la fois, une demande pendant un scan lève un drapeau `rescanPending`, et un nouveau scan part à la fin. Deux instantanés d'une même session ne peuvent donc pas arriver dans le désordre. Déclenché par `DispatchSource` vnode (avec anti-rebond) et au retour d'activation de la fenêtre (SMB n'envoie pas tout). Un instantané est **fusionné ainsi** :
- `sessionID` différent de la liste active (autre dossier ouvert entre-temps) → jeté ;
- génération antérieure à la dernière opération de fichier terminée → jeté et rescan relancé ;
- les URL ayant une opération en cours (tombstones) sont retirées du résultat ;
- la photo courante est conservée par URL ; une `key` changée invalide de fait ses frames.

Photo disparue → retirée, on passe à la suivante.

### Suppression

Chaque suppression crée d'abord un `TrashOp { photo, indexOrigine, état: pending|done(trashURL)|failed, undoDemandé }`, sur le main.

1. Touche Supprimer (`keyDown` non répété : **`isARepeat` ignoré**, pour que maintenir la touche ne vide pas le dossier), acceptée seulement si la photo est visible (principe 4).
2. Tombstone posé, retrait optimiste de la liste, affichage synchrone de la photo suivante du dossier (ou dans le sens de navigation, selon le réglage ; la précédente si c'était la dernière). Aucune confirmation : c'est réversible. La photo n'étant plus dans la liste, une double suppression est impossible.
3. File série (FIFO) : la révision sur disque est revérifiée. Différente de `key` (fichier remplacé entre-temps) → **pas de suppression**, photo réinsérée, alerte. Sinon `FileManager.trashItem`, l'URL en corbeille est conservée dans l'opération.
4. Échec : réinsertion à sa place triée, alerte. Volume sans corbeille (SMB) : alerte proposant une suppression **définitive**, confirmée à chaque fois, et qui n'entre jamais dans la pile d'annulation.
5. ⌘Z prend la dernière opération. Si `pending`, marque `undoDemandé` : l'annulation s'exécute à la fin du trash (succès → restauration, échec → déjà réinsérée). Si `done`, met le déplacement retour dans la même file. `moveItem` ne remplace jamais : si le chemin d'origine est occupé, erreur explicite. Réinsertion et navigation dessus.
6. Quitter attend la fin de la file (`applicationShouldTerminate` → `.terminateLater`).
7. Le tombstone est levé à la fin de l'opération, ce qui incrémente `opGeneration`.

Seul l'ARW est supprimé : les JPEG et XMP de même nom ne sont pas touchés en v1 (une option multi-fichiers imposerait de gérer les réussites partielles).

## 6. Réglages et intégration système

- `Info.plist` : `CFBundleDocumentTypes` avec `LSHandlerRank = Alternate` (n'usurpe rien) pour ARW, CR2, CR3, NEF, NRW, RAF, DNG, ORF, RW2, PEF, SRW (UTI système `com.sony.arw-raw-image` etc., vérifiées au build).
- Réglages : une case par format, `NSWorkspace.setDefaultApplication(at:toOpen:completion:)`, appels sérialisés par type, erreurs affichées (le système peut demander un consentement ou refuser). L'état affiché est relu via `urlForApplication(toOpen:)` après chaque changement, jamais stocké. Le bundle précédent est mémorisé ; il n'est restauré à la désactivation que si BetterView est toujours le gestionnaire effectif et que cette app existe encore.
- Non sandboxé (requis : un double-clic ne donne accès qu'au fichier en sandbox, pas à ses voisins). Hardened runtime. Signature locale, script d'installation vers `/Applications`.

Raccourcis : `ShortcutMap` associe chaque action à ses touches, enregistrées dans `UserDefaults` ; une touche n'appartient qu'à une action, et l'attribuer ailleurs la retire de la première. Les lettres sont stockées par caractère (valable en AZERTY), les touches spéciales par code. La vue répond à toutes les touches, le menu affiche la première. ⌘Q, ⌘W, ⌘O et ⌘, sont réservés. Une touche sans modificateur n'entre jamais dans le menu pour la suppression : elle agirait aussi depuis la fenêtre de réglages. La liste par défaut est dans le README.

## 7. Objectifs vérifiables

Mode `--bench <dossier>` intégré, plus `os_signpost`, sur de vrais ARW. Conditions : SSD interne, dossier de 500 photos, cibles provisoires jusqu'à M0.

| Scénario | Objectif |
|---|---|
| Navigation S en cache, input → commit sur le main | p99 < 8 ms |
| Même scénario, input → image présentée | p99 < 2 frames (M0 dit comment le mesurer) |
| Tri normal (1 photo/s), part d'arrivées sur S, cache disque vide | > 99 % après 2 s |
| Touche maintenue (30 Hz), part d'arrivées sur P ou mieux, après 300 ms | > 95 % |
| Fichier courant sans cache, S disponible sous charge de fond | p95 < 650 ms (révisé en M0 : l'objectif initial de 450 ms n'est pas atteint) |
| Lancement à froid → premier pixel (avec aperçu) | < 300 ms |
| Suppression → photo suivante affichée | < 8 ms si la suivante est en cache |
| Empreinte `phys_footprint` au repos | 1,7 Go + 400 Mo. Pendant les rendus, le pool Core Image s'ajoute (section 11) |

## 8. Jalons

- **M0, verrou technique (avant tout le reste)** : commit `contents` IOSurface vs CGImage et délai jusqu'à présentation réelle, étiquette couleur P3 (comparaison de pixels), workers CIRAW (ordre aléatoire, plusieurs passes), latence de la demande visible sous charge S/F/fond, empreinte mémoire réelle, lecture à froid, carte SD. Le choix IOSurface, le nombre de slots et les objectifs chiffrés peuvent changer ici.
- M1 : ouverture, navigation P, suppression + annulation (tests).
- M2 : pipeline S/F, cache RAM, planner (tests).
- M3 : cache disque, inactivité, pression mémoire.
- M4 : réglages, associations, bench complet, installation.

Tests unitaires : WindowPlanner (priorités, pression mémoire, répétition), FrameCache, clés et échecs DiskCache, fusion PhotoList. Scénarios imposés :
- A puis B supprimés pendant un rescan : aucune résurrection ;
- ⌘Z pendant que le trash est `pending` ;
- fichier remplacé à la même URL : frame ancienne jamais affichée, suppression refusée ;
- fichier remplacé entre le premier contrôle et le décodage : résultat rejeté, rien sur disque ;
- changement externe pendant un scan : le scan suivant gagne ; dossier B ouvert pendant le scan de A : instantané de A rejeté ;
- fichier sans aperçu et cache vide : premier pixel obtenu ;
- entrée disque manquante : rendu RAW relancé ;
- restauration du gestionnaire seulement s'il n'a pas changé ailleurs.

## 9. Alternatives écartées

| Alternative | Raison |
|---|---|
| LibRaw | Dépendance C, licence, CPU seulement, alors que CIRAW sur GPU est plus rapide et déjà là. Filet de secours si Apple retirait un format. |
| SwiftUI pour le visualiseur | Diffing et état observables sur le chemin critique, sans bénéfice ici. |
| Vue Metal maison | Core Animation suffit pour une image plein cadre ; à réévaluer si M0 échoue. |
| NSDocument | Machinerie inutile pour une liste d'images. |
| Base de données d'index | Le scan hors main et le `Set` de clés suffisent ; rien à interroger. |
| Acteurs Swift par composant | Sauts d'exécuteur et complexité ; le main thread comme seul propriétaire de l'état reste plus simple. |

## 10. Risques

| Risque | Parade |
|---|---|
| Commit IOSurface plus lent ou mal colorimétré que prévu | M0, repli sur CGImage |
| Saturation GPU | Slot réservé à la demande visible ; slots réduits en mode économie ou thermique ≥ serious |
| Mises à jour macOS changeant le rendu RAW | Version macOS incluse dans la clé |
| Stockage lent (SD, SMB) | P ne lit que quelques centaines de Ko ; fenêtre réduite selon temps mesuré |

## 11. Écarts issus de M0 et résultats mesurés

L'architecture v3 a été relue et validée avant le code. Ces écarts viennent des mesures de M0 et de l'implémentation ; le code lui-même n'a pas eu de relecture indépendante.

| Décision | Mesure qui la justifie |
|---|---|
| IOSurface pour **tous** les tiers, y compris P | Commit stable (p95 ≤ 2,3 ms) ; CGImage monte à 51 ms au premier affichage (envoi au GPU). Couleur identique au pixel près. |
| P des `.arw` découpé directement du TIFF (`ARWPreview`), repli sur ImageIO pour le reste | Premier aperçu 225 → 55 ms, puis 30 → 15 ms. Le plugin RAW d'ImageIO n'est plus chargé au lancement. Vérifié sur 133 fichiers réels (orientations 1, 6, 8) : 0 pixel d'écart avec ImageIO (`--verify-previews`). |
| `CIContext` partagé, **sans** `clearCaches()` ni `memoryTarget` | `clearCaches()` en concurrence : p95 de 355 ms à plus de 3 s. `memoryTarget` : aucun gain à 1024 Mo, latence triplée à 512 Mo. |
| Un seul rendu F à la fois | Le pool Core Image atteint 2,6 Go avec un seul F et 3,3 Go avec deux. |
| Pendant un rendu visible, 1 seul travail spéculatif démarre | Deux rendus concurrents sont l'optimum (6,8 images/s, p50 279 ms) ; à trois, le p50 monte à 390 ms. |
| F du courant planifié dès 500 ms, avant la fenêtre S | Zoom après 1,2 s sur une photo : 280 → 1,2 ms. |
| Préchauffage Core Image décalé de 300 ms | Il concurrençait le premier aperçu : lancement de 330-500 à 250-296 ms. Un rendu qui arrive avant initialise le contexte lui-même : pas de dépendance circulaire (A3). |
| Option « supprimer aussi JPEG/XMP » retirée | Réussites partielles non gérées. |
| Position AF lue dans l'en-tête déjà lu pour P, conservée par `PhotoKey` | 562 ARW réels de l'A7C : 562 positions, 0 écart avec `exiftool` (position, orientation, mode AF), 0 écart de proportions avec l'extent de CIRAWFilter (`--verify-af`). Contrôle visuel en paysage et en orientations 3, 6 et 8. Bench inchangé (ci-dessous). |
| Position de zoom bornée pour l'affichage seulement | Avec P à 1616×1080, la position du point AF était ramenée au centre avant l'arrivée de S. |

Résultats de `--bench` (Release, M1 Pro 16 Go, 133 ARW sur SSD interne, cache disque vide au départ) :

| Scénario | Objectif | Mesuré | État |
|---|---|---|---|
| Navigation, input → commit | p99 < 8 ms | 1,0 ms (p50 0,5) | Atteint |
| Tri à 1 photo/s, arrivées en S | > 99 % | 100 % | Atteint |
| Tri à 3 photos/s, arrivées en S | non fixé | 100 % | |
| Touche maintenue 30 Hz, P ou mieux | > 95 % | 100 %, 0 écran vide | Atteint |
| Lancement → premier pixel | < 300 ms | 247-296 ms | Atteint |
| Suppression → photo suivante | < 8 ms | 1,4 ms au p99 | Atteint |
| Zoom préparé (photo vue > 1 s) | non fixé | 1,2 ms | |
| Zoom non préparé | non fixé | jusqu'à 470 ms | |
| Relecture du cache disque, jusqu'à S | non fixé | p50 27 ms, p95 60 ms | |
| Saut vers une photo sans cache, jusqu'à S | p95 < 450 ms | p95 626 ms ; l'aperçu s'affiche entre-temps | **Non atteint**, objectif révisé |
| Empreinte au repos (3 s) | 2,1 Go | 1,6 Go pour 1,44 Go de frames | Atteint |
| Pic d'empreinte, pendant les rendus | non fixé | 4,2 Go, transitoire | À surveiller |

Point AF, `--bench` relancé (Release, mêmes 133 ARW, machine partagée avec d'autres compilations) en alternant `main` et la branche, deux passes chacun : navigation au p99 0,7-2,2 ms contre 0,7-2,1 ms, arrivées en S 100 % dans les deux cas, touche maintenue 38,7 % S et 0 écran vide dans les deux, saut sans cache p95 464-521 ms contre 491-566 ms. Le lancement varie de 216 à 622 ms d'une passe à l'autre pour les deux versions (machine chargée) : pas d'écart attribuable. Une passe isolée de la branche, sous forte charge extérieure, a été écartée (saut à 2,5 s).
Fenêtre à la forme de la photo, avec une immersion plein écran depuis retirée (mesures à refaire), même machine, même dossier, version précédente puis version actuelle (`--bench`, un passage chacun) : navigation à 1 photo/s p99 1,0 → 3,0 ms (le changement de forme de la fenêtre, objectif de 8 ms tenu), touche maintenue p99 2,0 → 1,9 ms, suppression p99 1,0 → 1,3 ms, lancement 358 → 218 ms. Zoom immédiat p50 452 → 742 ms sur 6 mesures seulement : écart non expliqué, à reconfirmer.

Bande d'aperçu affichée, même machine, même dossier, `main` puis cette version (`--bench`, un passage chacun, donc comparaison indicative) : navigation à 1 photo/s p99 9,7 → 5,0 ms, touche maintenue p99 2,5 → 2,1 ms, suppression p99 2,2 → 2,5 ms, empreinte au repos 1,67 → 1,60 Go. Aucune dégradation visible ; l'écart à 1 photo/s reste dans le bruit d'un passage unique.

Non mesuré : latence jusqu'à l'image réellement présentée à l'écran (seul le commit l'est), lecture à froid, carte SD, volume SMB, écran 6K.


### Validation après intégration du zoom AF (2026-11-08)

135 tests passent après fusion de `main` (raccourcis configurables, bande et comparaison). Council GPT-6.1 Sol medium : APPROVE sur `db5d743`, seconde instance du même modèle autorisée explicitement. A rejoint `ShortcutAction` ; la comparaison conserve son zoom synchronisé et ignore cette action AF, réservée à la vue normale.

Sur les 403 ARW actuellement présents dans `~/Pictures`, `--verify-af` retrouve 403 positions (68 au centre), aucune incohérence avec l’extent Apple. Comparaison séparée avec ExifTool : aucun écart de position, orientation ou mode AF.

Bench Release sur ces 403 fichiers : après une première passe perturbée (saut sans cache p95 1059 ms), une passe de référence `main`, puis une seconde passe AF donnent respectivement un p99 de navigation à 1 photo/s de 5,5 et 5,6 ms, touche maintenue 2,2 et 2,1 ms, saut sans cache p95 613 et 593 ms. Aucun écran vide ; arrivées S/F 100 % à 1 et 3 photos/s. La seconde passe AF démarre en 378 ms et tient 1762 Mo au repos. Les premiers lancements des deux binaires neufs ont pris environ 20 s ; un contrôle de lancement AF suivant prend 403 ms. Ces délais initiaux restent inexpliqués et ne sont pas spécifiques à la branche. Mesures indicatives sur une machine partagée ; aucune régression reproductible identifiée.
