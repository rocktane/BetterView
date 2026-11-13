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
Settings : Preferences, FileAssociations, CacheSettings, KeyRecorder, vues SwiftUI dans un NSTabViewController (SettingsWindow)
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

`ViewerView` : NSView layer-hosting, un seul `CALayer` image, `contents` assigné dans une `CATransaction` sans action. `contentsGravity` et géométrie calculés sur les dimensions logiques natives, ce qui permet de permuter P/S/F sans saut de géométrie. Zoom : transformation de layer, F remplace S à son arrivée. Grossissement > 100 % en `nearest`. Changer de photo revient à l'ajusté (`ViewerController.display`, au changement de fichier affiché), mode AF compris : la nouvelle photo s'ouvre entière, dans sa propre forme de fenêtre. Le réglage « Conserver le zoom en changeant de photo » (Général > Affichage, désactivé par défaut, `Preferences.keepsZoomAcrossPhotos`) rétablit l'ancien comportement : le zoom et sa position sont conservés entre photos, et le mode suivi AF se propage. Il n'est lu qu'au changement de photo pendant un zoom. Un fichier réécrit sur place (même chemin) garde le zoom. La position demandée est bornée aux bords **pour la mise en page seulement** : P n'a souvent pas la taille de la photo (sur l'A7C, le SubIFD qui la donne est au-delà des 64 Kio lus, P garde donc la taille du JPEG, 1616×1080), et borner la position mémorisée sur cette taille la détruisait avant l'arrivée de S. Seul le déplacement à la main mémorise une position bornée. IOSurface étiquetée en P3 : `IOSurfaceSetValue(surface, kIOSurfaceColorSpace, CGColorSpaceCopyPropertyList(p3))`, vérifiée visuellement en M0.

### Point AF

Commande A : 100 % sur la position AF enregistrée par le boîtier. Le zoom Z (centré sur le curseur) ne change pas.

- **Source.** MakerNote Sony, tag `0x2027` FocusLocation : largeur, hauteur, x, y en 16 bits non signés, en coordonnées capteur (paysage, origine en haut à gauche). Chemin : IFD0 → IFD EXIF (`0x8769`) → MakerNote (`0x927C`). Sur l'A7C, le MakerNote n'a pas d'en-tête et ses offsets comptent depuis le début du fichier ; un en-tête `SONY DSC ` ou `SONY CAM ` (anciens boîtiers) est sauté avec les mêmes offsets ; tout autre en-tête est refusé. Le tag `0x201B` FocusMode (0 = manuel) est lu au passage. Tout est en clair : les blocs chiffrés (`0x2010`, `0x9050`, `0x94xx`) ne servent pas. ImageIO n'expose pas cette valeur. Une valeur hors des 64 Kio déjà lus est traitée comme absente : jamais de lecture en plus.
- **Orientation.** Conversion vers l'image droite : 1 → (x, y) ; 3 → (L − x, H − y) ; 6 → (H − y, x) ; 8 → (y, L − x), puis normalisation. CIRAWFilter rend les ARW de l'A7C en 6000×4000 (ou 4000×6000) orientés, origine 0, sans recadrage : exactement le repère de FocusLocation (`DefaultCropSize` = 6000×4000 dans un capteur de 6048×4024). La position normalisée retombe donc sur le même pixel, quelle que soit l'échelle de la frame affichée.
- **Mode suivi.** Par défaut, changer de photo quitte le zoom et donc le mode. Avec le réglage « Conserver le zoom en changeant de photo », A active un mode qui dure tant que le zoom est actif : chaque photo affichée (navigation, suppression, ouverture) est centrée sur sa propre position AF, au grossissement courant, ce qui permet de comparer la netteté d'une rafale au point visé ; déplacer ou pincer ne quitte pas le mode, et la photo suivante se recentre sur son point AF. Dans les deux cas, A une seconde fois, Z, Échap, double-clic ou pincement jusqu'à l'ajusté : retour à l'ajusté et fin du mode. Si la position n'est pas encore lue (photo jamais préparée), la vue se centre provisoirement au milieu, puis se recentre à l'arrivée de l'en-tête (≈ 15-30 ms, avec P), sauf si l'utilisateur a déjà déplacé l'image.
- **Absence.** Pas de position (autre format, tag absent) ou mise au point manuelle : zoom au centre, et une mention dans le badge (« Pas de point AF : centre », « Mise au point manuelle : centre »). Pas de bip : en mode suivi, il sonnerait à chaque photo, et le centre est aussi le repli du boîtier.
- **Repère.** Un cercle fin blanc, 22 pt, avec ombre, affiché seulement dans ce mode. Pas de vert ni de cadre AF : rien ne doit laisser croire que la mise au point y est garantie.
- **Centre exact.** Sur 562 ARW réels, 71 ont exactement (3000, 2000) : 56 en zone AF « Centre » (attendu), 2 en suivi des visages avec la zone « Centre », 13 en « Large », mode où les mêmes valeurs reviennent souvent (x = 1818, 2053, 3000, 3946, 4181 ; y = 1341, 1500, 2000, 2658), comme des positions de collimateurs dont le centre ferait partie. Rien ne montre un repli faute de position : le centre est traité comme une vraie position. Le zoom serait de toute façon identique.
- **Ce que la valeur ne dit pas.** Exemple observé (A7C03320, suivi des visages, 3 visages détectés) : la position enregistrée tombe au-dessus d'une tête, hors des cadres de visage que le boîtier a lui-même enregistrés. La vue montre la valeur du boîtier telle quelle.
**Forme de la fenêtre** (`WindowShape`, `ViewerController.applyWindowShape`) : la fenêtre prend le ratio de la photo, ce qui supprime les bordures sans rien recadrer. Un rendu lui donne toujours sa forme exacte ; un aperçu, dont la taille vient d'un en-tête légèrement différent, ne la change que si le ratio s'écarte de plus de 1 %. Elle ne change pas pendant un zoom : par défaut, changer de photo quitte le zoom ; avec le réglage qui le conserve, la fenêtre garde sa forme d'une photo à l'autre. L'image couvre toujours la vue (le plus grand des deux rapports), donc un arrondi ne peut pas ouvrir de bande. Le tier S reste ajusté à l'écran : une photo portrait est affichée à sa pleine définition de rendu.

**Fenêtre seule** : aucun plein écran, natif ou non, et donc aucune touche pour y aller. La barre de titre est invisible. Glisser la photo déplace la fenêtre, sauf en zoom où cela déplace l'image. La fenêtre conserve sa hauteur d'une orientation à l'autre, seule sa largeur change, et les contraintes du bandeau restent sous les priorités de la fenêtre, pour que le texte ne lui impose pas de largeur minimale.

**Survol** : boutons, trois lignes en bas à gauche (nom ; ISO, vitesse, ouverture, focale ; date), position en bas à droite et marqueur « Aperçu » ne s'affichent que si le pointeur est sur la photo. L'état est relu à chaque changement de forme, car une fenêtre qui change sous un pointeur immobile n'envoie aucun événement, et chaque relecture réapplique l'état réel (alpha et masquage des panneaux et des boutons de fenêtre), même si la réponse n'a pas changé : un écart né ailleurs ne survit pas. Filet : tout mouvement du pointeur sur la photo (`mouseMoved`) affiche ces éléments en se fiant à l'événement lui-même, car `NSWindow.windowNumber(at:)` peut désigner un instant une autre fenêtre (bulle d'aide, sélecteur d'apps, bannière) qui disparaît ensuite sans aucun événement. Quand tout est déjà affiché, ce n'est que quelques lectures de propriétés, et rien sur le chemin de navigation. Un fondu de sortie qui s'achève après un retour du pointeur ne masque plus la vue (`fade`, compteur par vue). Le message d'erreur de décodage reste toujours visible : il porte le nom du fichier qu'une suppression viserait.

**Informations** : `MetadataStore` lit l'EXIF hors main, un fichier à la fois, le plus récent d'abord, et anticipe sur les photos voisines. Pour les `.arw`, lecture directe des 64 premiers Ko (`PhotoMetadata.parse`), sans charger le plugin RAW d'ImageIO ; repli sur ImageIO sinon. Vérifié sur 133 fichiers réels par `--verify-previews` : valeurs identiques à ImageIO. La date reste celle de l'appareil, l'EXIF n'ayant pas de fuseau.



### Bande d'aperçu

La fenêtre change de largeur à chaque photo : la bande vit donc dans son propre `NSPanel` (`StripPanel`), flottant et sans activation. Il ne devient jamais fenêtre clé, donc le clavier reste à la visionneuse, et il ne s'affiche que lorsque la fenêtre de la photo a le focus : app active et fenêtre de la photo clé. Le contrôleur dit seulement s'il veut la bande (`setVisible`) ; `StripPanel` applique la règle et la réévalue à chaque changement de fenêtre clé ou d'activation de l'app. Une mise à jour de la bande (navigation, fin de zoom, sortie de comparaison, changement d'écran) ne peut donc plus la faire réapparaître sans le focus, et un clic sur une autre fenêtre de BetterView (réglages, historique des suppressions, feuille d'alerte ou d'ouverture), qui ne désactive pas l'app, la masque aussi. `hidesOnDeactivate` est désactivé : AppKit la réaffichait à la réactivation, avant que la fenêtre de la photo redevienne clé, ou même si elle ne le redevenait pas. Elle reste affichée pendant un zoom (la fenêtre ne change alors pas de forme) et disparaît pendant la comparaison, qui a sa propre rangée.

**Aimants** (`StripMagnet`, pur et testé) : le bord du Dock se déduit de l'écart entre `frame` et `visibleFrame` (bas si le Dock est masqué) ; le centre est celui de `visibleFrame`, sur chaque axe indépendamment. La position proposée suit toujours le pointeur : s'éloigner au-delà de la portée (36 pt pour le Dock, 24 pt pour le centre) suffit à décrocher. C'est `StripPlacement` qui est mémorisé, avec les aimants qui retiennent la bande, et non la seule position : une bande retenue suit le Dock et les changements d'écran.

**Aimant de la fenêtre** (`StripMagnet.windowSnap`, `StripWindowHold`, purs et testés) : glissée près du bord bas de la fenêtre de la photo, la bande s'y accroche dessous, à l'extérieur, avec le même écart que pour le Dock (8 pt), et sur le centre de la fenêtre si son centre passe à moins de 24 pt. Il faut que la bande chevauche la fenêtre en largeur, et qu'il y ait la place sous la fenêtre dans l'écran visible. Le bord haut n'attrape pas : un seul emplacement, choisi parmi « dessous ou dessus » et « posée sur le bas de la photo », est plus prévisible. Priorité : la fenêtre passe avant le Dock et le centre de l'écran, qui ne s'appliquent plus tant qu'elle tient la bande. Mémorisé dans `StripPlacement.window` : le centrage, ou sinon l'écart horizontal au centre de la fenêtre, qui change de largeur autour de son centre à chaque photo. Une bande non centrée garde donc sa place relative. Portée de 36 pt, au-delà la bande décroche, avec le même retour haptique qu'avec les autres aimants.

Suivi : tant que la fenêtre la tient, la bande est une fenêtre enfant de la visionneuse (niveau flottant rétabli), donc le serveur de fenêtres la déplace avec elle pendant qu'on la glisse, sans retard. Un changement de forme ou un déplacement repasse par `followViewer` dans `windowDidResize`/`windowDidMove`, dans le même tour que le `setFrame` de la fenêtre : un seul `setFrame` du panneau, et seulement si la forme change (la navigation entre photos de même forme ne touche pas à la bande). La mise à jour de la bande, après l'image, refait le calcul au cas où. Sans place (fenêtre de toute la hauteur de l'écran, ou fenêtre glissée en bas), la bande est bornée à l'écran visible, par-dessus la photo, et reprend sa place dès que la fenêtre la lui rend. La fenêtre ne tient la bande que si elle est affichée, non réduite, hors comparaison et hors fenêtre d'accueil : sinon la bande reste à sa dernière position (masquée en comparaison, en réduction et à la fermeture), et elle revient contre la fenêtre quand celle-ci retrouve une photo. Au lancement, la position se recalcule sur la fenêtre restaurée ; un changement d'écran passe par le même calcul, sur l'écran de la fenêtre.

**Taille** (`StripResize`, pur et testé) : une bande de prise à l'intérieur de chaque côté étire la bande : 8 pt à gauche et à droite, sur la partie estompée, 6 pt en haut et en bas, dans les marges de 8 pt au-dessus et au-dessous des photos. Près d'un coin (14 pt, l'arrondi), les deux côtés qu'il joint s'étirent ensemble. Le curseur de redimensionnement (côté ou coin) y est posé à la main : le panneau ne devient jamais clé, les cursor rects ne s'y appliquent pas. Un appui qui ne bouge pas de 4 pt reste un clic ; glisser depuis les photos déplace toujours la bande (les marges haute et basse ne la déplacent plus), et le défilement n'est pas concerné. Sur chaque axe, ce qui reste en place suit les aimants : le centre pour une bande centrée (les deux côtés suivent le pointeur), le côté tenu (Dock à gauche ou à droite pour la largeur, Dock en bas pour la hauteur, bord de la fenêtre pour une bande accrochée dessous, qui grandit vers le bas), sinon le côté opposé à celui qu'on tire. Bornes : 300 × 66 pt ; la largeur visible de l'écran moins l'écart du Dock de chaque côté, et 162 pt de haut (vignettes de 66 à 146 pt), sans jamais sortir de l'écran visible. La taille choisie (`StripSize`, mémorisée à part de `StripPlacement`) est conservée telle quelle : un écran plus petit l'affiche réduite, un écran plus grand la rend. La hauteur des vignettes suit celle de la bande (`StripPanel.metrics(height:)`) et change avant le cadre, et la vue redessine dans la même transaction que son changement de taille : la photo courante reste au milieu à chaque pas, rien n'est étiré entre deux. Le nombre de photos données à la bande suit sa taille (`StripView.reach`, assez pour la remplir de photos portrait), 14 de chaque côté au minimum. La rangée de la comparaison a ses propres métriques et ne change pas.

**Vignettes** (`ThumbnailStore`) : en priorité basse, sur leur propre file, 2 à la fois, et ce qui attend est remplacé à chaque navigation. Elles ne viennent pas du pipeline : P est évincé dès que S existe, et garder des frames pour la bande retiendrait de la mémoire hors budget. Leur grand côté suit la hauteur de la bande pour rester net sur l'écran de la bande (une photo 3:2, à l'échelle de l'écran), par paliers de 80 px à partir de 200 px : 200 px pour la bande habituelle, 440 px au plus sur un écran Retina. Une vignette trop petite reste affichée jusqu'à l'arrivée de la plus grande, sans trou. Budget de 40 Mo, compté en octets : quand il est atteint, les vignettes que la bande ne demande plus partent d'abord, et tout part seulement si celles qu'elle montre n'y tiennent pas (`ThumbnailStore.evicted`, testé). Environ 380 vignettes de 106 Ko à 200 px, environ 80 de 516 Ko à 440 px, deux fois ce que montre la bande la plus large avec sa marge.

**Mise à jour** : après l'image, au plus une fois par tour de boucle, en affectant des pointeurs à des layers. Chaque vignette a la largeur de sa photo à hauteur fixe ; avant l'arrivée de sa vignette, elle prend du 3:2. Les vignettes sont demandées bien au-delà des bords, donc ce décalage ne se voit qu'en sautant loin. La photo courante reste au milieu, sauf aux extrémités du dossier où la bande s'arrête pour ne pas laisser de vide, et les vignettes coupées par les bords s'estompent.

**Rafales** (`PhotoGroups`) : photos consécutives prises à 2 s d'écart au plus, d'après l'heure EXIF déjà lue par `MetadataStore`. Elles sont cherchées à ±12 photos de la courante, ce qui borne une rafale à 25 photos. Une rafale qui dépasse ce rayon n'est donc vue qu'en partie. Aucune analyse d'image : c'est prévisible, mais deux cadrages proches pris à 10 s d'écart ne sont pas regroupés (Maj+clic couvre ce cas).

### Comparaison

Un mode de la même fenêtre : `ComparisonView` remplace la vue de contenu, la fenêtre prend presque tout l'écran, puis retrouve son cadre exact en sortant. Le nom d'autosave est retiré pendant ce temps, pour que ce grand cadre ne revienne pas au lancement suivant.

`ComparisonModel` (pur, testé) tient 4 emplacements et une file d'attente. Une photo retirée est remplacée sur place par la suivante en attente. À 4 ou 3 photos la grille reste en 2×2 avec une case vide, pour que rien ne bouge ; à 2 elles se partagent l'espace. Quand il n'en reste qu'une, retour à la vue normale, sur cette photo.

**Sécurité** (principe 4) : la suppression n'agit que sur un emplacement qui montre vraiment sa photo. « Garder celle-ci » exige que toutes les photos affichées soient visibles, et ne touche jamais la file d'attente, que personne n'a encore vue. Un fichier modifié sur le disque n'est pas supprimé, comme ailleurs.

**Survol** : les boutons « Corbeille » et « Garder celle-ci » sont sur l'emplacement survolé, pas sur la photo choisie. Un clic y choisit d'abord cette photo, puis passe par les mêmes commandes, donc les mêmes garde-fous que le clavier ; il est refusé si l'emplacement ne montre plus la photo qui portait le bouton, et un double-clic ne compte que pour un clic (le second viserait la photo qui vient de prendre la place). Le survol seul ne déplace pas le choix. Comme dans la vue normale, l'emplacement survolé est relu à chaque changement des emplacements (photo remplacée, grille de 4 à 2, entrée dans la comparaison, retour au premier plan), car rien ne bouge alors sous le pointeur.

**Annulation** : `LibrarySession.trash(_:)` donne le même groupe aux opérations d'un même geste, et ⌘Z restaure tout le groupe. Toute photo retirée qui réapparaît dans la liste (annulation, échec de la corbeille, fichier modifié) retrouve son emplacement dans la comparaison, quel que soit l'ordre d'arrivée. Volume sans corbeille : une alerte par photo, comme pour une suppression seule.

**Zoom AF (A)** : chaque emplacement a une ancre, sa position AF (`FocusAnchor`), et tous partagent un décalage exprimé en pixels de l'image (`focusOffset`). Le grossissement étant commun, ce décalage fait la même distance à l'écran dans chaque emplacement, y compris après un pincement. Z garde son modèle : un seul point, normalisé, commun à toutes les photos. Le bornage aux bords se fait par photo et pour l'affichage seulement (`ComparisonGeometry.imageFrame`) ; le décalage mémorisé est borné à l'union des plages des photos affichées (`clampedOffset`), pour qu'une photo arrivée au bord n'arrête pas les autres et qu'un déplacement ne se perde pas au-delà de tous les bords. Sans position (autre format, tag absent) ou en mise au point manuelle : ancre au milieu, mention dans le badge de l'emplacement, pas de cercle. Position pas encore lue : ancre au milieu, puis recentrage à l'arrivée de l'en-tête (`Pipeline.onFocus`), sauf si l'utilisateur a déplacé les photos depuis ; le cercle apparaît dans tous les cas. L'en-tête est demandé pour toutes les photos affichées : chacune est une demande visible de P, et P lit la position (ou un travail `.focus` seul si S est déjà là). Une photo qui remplace une autre s'ouvre sur sa position plus le décalage commun, pour que toutes restent décalées du même écart. A une seconde fois, Z, Échap, double-clic ou pincement jusqu'à l'ajusté : retour à l'ajusté et fin du mode. Le planning F ne change pas : F rend la photo entière, quel que soit l'endroit regardé.

**Pipeline** : `PlanInput.comparison` remplace la fenêtre autour de la photo courante. Toutes les photos affichées sont une demande visible, et leur S est préparé pour les 4 suivantes en attente. En zoom, F de chacune, la photo choisie d'abord. Un seul rendu F à la fois (section 11), soit environ 1,3 s pour 4 photos au premier zoom, pendant lesquelles chaque emplacement affiche S et un marqueur. Le budget F est doublé pendant la comparaison pour que 4 photos tiennent, puis rétabli. Sous pression mémoire, seule la photo choisie reste nette, et les autres emplacements relâchent aussitôt leurs surfaces évincées. Une photo sans aperçu embarqué garde son S déjà rendu ; si elle n'en avait pas encore, l'emplacement affiche son nom, sa suppression reste refusée, et elle se rend dès qu'on la choisit ou que la pression retombe.

### PhotoList et dossier

État main : tableau trié par `localizedStandardCompare` du nom, de `Photo { url, key }`. Extensions acceptées : celles de la section Réglages. Un seul fichier ouvert → affichage **immédiat** avec une liste provisoire `[fichier]`, sans attendre le scan ; plusieurs fichiers sélectionnés → ces fichiers seulement.

`FolderScanner` tourne hors main (énumération, stat, tri, état de protection) et publie un instantané portant le `sessionID` de la liste et le `opGeneration` lus à son lancement. Il est à exécution unique par session : un seul scan à la fois, une demande pendant un scan lève un drapeau `rescanPending`, et un nouveau scan part à la fin. Deux instantanés d'une même session ne peuvent donc pas arriver dans le désordre. Déclenché par `DispatchSource` vnode (avec anti-rebond) et au retour d'activation de la fenêtre (SMB n'envoie pas tout). Un instantané est **fusionné ainsi** :
- `sessionID` différent de la liste active (autre dossier ouvert entre-temps) → jeté ;
- génération antérieure à la dernière opération de fichier terminée → jeté et rescan relancé ;
- les URL ayant une opération en cours (tombstones) sont retirées du résultat ;
- la photo courante est conservée par URL ; une `key` changée invalide de fait ses frames.

Photo disparue → retirée, on passe à la suivante.

### Suppression

Chaque suppression crée d'abord, sur le main, un `DeletionRecord { id, origine, révision source, date, phase, URL en corbeille, révision en corbeille }` et, tant que le déplacement n'est pas fini, un `TrashOp { photo, record, undoDemandé }`. La pile d'annulation ne contient que des identifiants d'enregistrements de ce lancement.

1. Touche Supprimer (`keyDown` non répété : **`isARepeat` ignoré**, pour que maintenir la touche ne vide pas le dossier), acceptée seulement si la photo est visible (principe 4).
2. Tombstone posé, retrait optimiste de la liste, affichage synchrone de la photo suivante du dossier (ou dans le sens de navigation, selon le réglage ; la précédente si c'était la dernière). Aucune confirmation : c'est réversible. La photo n'étant plus dans la liste, une double suppression est impossible.
3. File série (FIFO) : la révision sur disque est revérifiée. Différente de `key` (fichier remplacé entre-temps) → **pas de suppression**, photo réinsérée, alerte. La protection est revérifiée dans le même `stat` (voir « Photos protégées ») : protégée → pas d'appel à la corbeille. Sinon `FileManager.trashItem` ; l'URL réellement renvoyée et la révision du fichier à cette URL sont conservées dans l'enregistrement.
4. Échec : alerte avec une cause typée (`TrashFailure`), et réinsertion à sa place triée **seulement si la liste active couvre le fichier** (même dossier, et parmi les fichiers choisis si seuls certains ont été ouverts). Après l'ouverture d'un autre dossier, le fichier reste simplement dans le sien. Seul « volume sans corbeille » (SMB) propose une suppression **définitive**, confirmée à chaque fois, qui n'entre jamais dans la pile d'annulation et apparaît dans l'historique comme « Supprimée définitivement ». Les autres causes n'offrent rien d'autre que de conserver le fichier.
5. ⌘Z prend le dernier geste (toutes les opérations de son groupe). Si `pending`, marque `undoDemandé` : la restauration part à la fin du trash. Sinon la restauration passe par la même file. La pile ne change qu'au résultat : une restauration refusée (nom d'origine occupé, accès refusé, autre erreur) reste annulable et ⌘Z la retente ; une source disparue ou remplacée en sort, puisque réessayer ne servirait à rien.
6. **Restauration** (`LibrarySession.restore(id)`, unique moteur pour ⌘Z et pour l'historique) : sur la file, `lstat` de l'URL en corbeille. Absente → « plus dans la corbeille » ; `EACCES`/`EPERM` → « inaccessible », distinct d'absent ; autre fichier (appareil, inode, taille ou mtime différents) → refus sans rien déplacer. Puis le chemin d'origine doit être libre, et `moveItem` ne remplace jamais de toute façon. Le fichier restauré n'entre dans la liste, sélectionné, que si la liste active le couvre ; sinon il retourne dans son dossier sur disque sans toucher à la liste ouverte.
7. Quitter attend la fin de la file (`applicationShouldTerminate` → `.terminateLater`).
8. Le tombstone est levé à la fin de l'opération, ce qui incrémente `opGeneration`.

#### Photos protégées

`FileProtection`, lue hors main dans le même `stat` que la révision, au scan puis dans la file d'opérations :
- `locked` : drapeaux `uchg`/`schg` (ou ajout seul `uappnd`/`sappnd`), qui font échouer unlink et rename (EPERM) ;
- `readOnly` : pas de droit d'écriture pour l'utilisateur (`access(W_OK)` → EACCES). La corbeille accepterait ce fichier (mesuré), on y lit une intention de protection.

L'état est **séparé de `PhotoKey`** : `chflags` et `chmod` ne changent que le ctime, pas le mtime (vérifié, et testé), donc ni les frames ni le cache disque ne sont invalidés. La session tient un dictionnaire `chemin → protection` remplacé à chaque instantané ; un changement qui ne touche que la protection émet `protectionChanged`, qui ne met à jour que le badge, sans replanifier. Le main ne lit jamais le disque pour ça.

Affichage : badge cadenas discret en haut à droite (à côté de « Aperçu »), visible comme les autres surimpressions quand le pointeur est sur la photo, posé après le commit de l'image par un lookup dans ce dictionnaire. Touche Supprimer sur une photo protégée connue : refus immédiat par un bandeau bref non modal (1,6 s), sans bip (le bip reste réservé à « photo non visible »), sans file ni E/S. Comparaison : le badge de l'emplacement indique « Protégée », ⌫ sur une photo protégée est refusé par le toast de la comparaison, et ↩ ne met à la corbeille que les autres photos non protégées (les protégées restent affichées, le toast les compte). `LibrarySession.trash(_:)` et `trashCurrent` écartent aussi toute photo connue comme protégée. Une protection posée après le scan est attrapée par la file : refus `locked`/`fileNotWritable` sans appeler la corbeille, et le dictionnaire est mis à jour pour que le badge et le refus immédiat s'appliquent ensuite. Une protection reconnue n'est **jamais** contournée : ni `chflags`, ni `chmod`, ni suppression forcée ; la suppression définitive la revérifie aussi.

Protection Sony (« Protéger » dans le boîtier) : la norme DCF la traduit par l'attribut lecture seule FAT/exFAT. **Non vérifié avec un vrai boîtier ni une vraie carte.** Vérifié sur des images disque FAT32 et exFAT montées par macOS 27 (pilotes FSKit, ceux d'une carte) : l'attribut lecture seule écrit directement dans l'entrée de répertoire apparaît comme `uchg` (le mode reste `rwx`, synthétique, et `chmod` n'y a aucun effet) ; inversement `chflags uchg` écrit cet attribut. Copie vers APFS : `uchg` survit à une copie Finder, `cp -p`, `ditto` et `FileManager.copyItem`, mais pas à `cp` simple. Import par Transfert d'images, Photos ou Imaging Edge : non vérifié.

Classement des échecs (`TrashFailure.classify`), d'après une relecture du disque (`TrashProbe` : protection, volume `MNT_RDONLY`, droit d'écriture du dossier) avant le code d'erreur, car les codes sont ambigus (mesuré avec `trashItem` sur images disque) : fichier verrouillé et dossier sans droit d'écriture donnent tous deux Cocoa 513 ; un **volume en lecture seule donne 3328, comme un volume sans corbeille**.

| Cause | Détection | Proposition |
|---|---|---|
| `locked` (protégée, verrouillée) | drapeaux | aucune |
| `fileNotWritable` | `access` sur le fichier | aucune |
| `readOnlyVolume` | `MNT_RDONLY`, EROFS, Cocoa 642 | aucune |
| `folderNotWritable` | `access` sur le dossier | aucune |
| `noTrash` | Cocoa 3328 sur volume inscriptible | suppression définitive confirmée |
| `other` (erreur passagère, inconnue) | le reste | aucune |

Le code 3328 d'un vrai partage SMB sans corbeille n'est pas vérifié : s'il différait, le fichier serait conservé (`other`), jamais supprimé.

Seul l'ARW est supprimé : les JPEG et XMP de même nom ne sont pas touchés en v1 (une option multi-fichiers imposerait de gérer les réussites partielles).

**Journal** (`DeletionJournal`) : `~/Library/Application Support/BetterView/suppressions.jsonl`, une ligne JSON par changement de phase, la dernière ligne d'un identifiant l'emporte. Pas de catalogue ni de base. Les lignes sont écrites (avec `fsync`) sur la file des opérations de fichier, dans le même bloc que le déplacement qu'elles décrivent : l'intention (`trashing`, `restoring`, `deleting`) **avant** le déplacement, le résultat après. Une interruption entre les deux est tranchée au lancement suivant d'après le disque seulement : fichier toujours à l'origine → rien ne s'est passé (entrée retirée) ; restauration interrompue → fichier encore à l'URL en corbeille avec sa révision : en corbeille, ou de retour à l'origine : restaurée ; sinon l'entrée est « à vérifier ». Jamais de parcours de `~/.Trash` : seules les URL renvoyées par les déplacements servent. Le chargement passe en premier sur la file, avant toute écriture du lancement ; il garde les 1 000 entrées les plus récentes et compacte le fichier. Le mode `--bench` n'écrit pas de journal.

**Historique** (Édition › Suppressions du dossier…, ⌘Y, réservé dans les raccourcis) : `DeletionHistory` sur le main reflète le journal ; `HistoryWindowController` (AppKit, `NSTableView`) montre les suppressions du dossier ouvert, ou du dernier ouvert (Ouvrir récent, sans E/S), les plus récentes en tête : aperçu, nom, date, et soit **Restaurer**, soit l'état en un mot (Restaurée, Plus dans la corbeille, Supprimée définitivement, À vérifier). Restaurer une entrée n'annule pas les suppressions suivantes. À l'ouverture de la fenêtre, l'URL en corbeille des entrées affichées est relue hors main (`lstat`) ; un refus s'explique dans une alerte et le bouton reste disponible. Fenêtre fermée, elle ne fait rien : aucun travail sur le chemin de navigation.

**Aperçus de l'historique** (`HistoryThumbnails`) : lus à la demande, pour les lignes à l'écran seulement, depuis l'URL en corbeille (ou l'origine si restaurée), par `Decoders.thumbnail(at:maxPixels:)` (JPEG découpé par `ARWPreview`, repli ImageIO sans décodage RAW), 360 px. Une seule lecture à la fois en qualité `utility`, sous les travaux du visualiseur ; une ligne qui quitte l'écran annule la sienne ; révision vérifiée avant et après la lecture. Petites `CGImage` seulement (aucune IOSurface), 200 au plus, vidées à la fermeture. Le cache disque S ne sert pas : il est invalidé à la suppression et ses clés dépendent du chemin source. Un aperçu absent n'empêche jamais la restauration.

## 6. Réglages et intégration système

- `Info.plist` : `CFBundleDocumentTypes` avec `LSHandlerRank = Alternate` (n'usurpe rien) pour ARW, CR2, CR3, NEF, NRW, RAF, DNG, ORF, RW2, PEF, SRW (UTI système `com.sony.arw-raw-image` etc., vérifiées au build).
- Non sandboxé (requis : un double-clic ne donne accès qu'au fichier en sandbox, pas à ses voisins). Hardened runtime. Signature locale, script d'installation vers `/Applications`.

### Fenêtre de réglages

`SettingsWindow` : un `NSTabViewController` en style barre d'outils (convention des réglages macOS), un `NSHostingController` SwiftUI par onglet, largeur 540 pt, la hauteur suit l'onglet (et le détail déplié).

- **Général > Affichage** : informations, bande d'aperçu, conserver le zoom en changeant de photo (désactivé par défaut), sens de navigation après une suppression.
- **Général > Formats RAW** : un interrupteur « Ouvrir les RAW avec BetterView » et une ligne de résumé (« 10 formats sur 11. ARW s'ouvre avec… »), puis le détail repliable en grille de cases, une par format. `NSWorkspace.setDefaultApplication(at:toOpen:completion:)` est appelé **un format à la fois**, y compris pour l'interrupteur global ; les erreurs sont regroupées en une alerte (le système peut demander un consentement ou refuser). L'état affiché est relu via `urlForApplication(toOpen:)` à l'ouverture, au retour au premier plan et après chaque changement, jamais stocké. Le bundle précédent est mémorisé ; il n'est restauré à la désactivation que si BetterView est toujours le gestionnaire effectif et que cette app existe encore.
- **Général > Cache disque** : taille maximale, espace utilisé (mesuré sur la file du cache, hors main), « Vider le cache… » avec confirmation.
- **Raccourcis** : liste groupée dérivée de `ShortcutAction`, plus les raccourcis fixes du menu de l'app (⌘O, ⌘,, ⌘Y, ⌘W, ⌘Q).

### Raccourcis

Une seule source : `ShortcutAction.spec` (`Sources/Model/Shortcuts.swift`), une ligne par commande avec titre, groupe des réglages, touches par défaut et répétition. Le clavier de la visionneuse et de la comparaison, la barre de menus et l'onglet Raccourcis en sont dérivés.

**Ajouter une commande** : un `case`, sa ligne dans `spec`, et son effet dans `ViewerController.perform` (et `performInComparison`) ; le compilateur réclame les deux derniers. Pour un élément de menu, ajouter `action(.nouvelle)` dans `AppDelegate.buildMenu`. Exemple :

```swift
case .history: Spec(title: "Historique des suppressions", group: .sorting, keys: [.character("y", modifiers: .command)])
```

La valeur brute du `case` est enregistrée avec les touches de l'utilisateur : ne jamais renommer un `case`. Une commande inconnue des données enregistrées (ajoutée depuis) reçoit ses touches par défaut si elles sont libres ; une commande retirée est ignorée. Un test vérifie qu'aucune touche par défaut n'appartient à deux commandes ni n'est réservée.

**Résolution** : `ShortcutMap` vit en mémoire ; `ShortcutStore` le lit une fois au lancement et l'enregistre (`UserDefaults`, clé `shortcuts`) à chaque changement, jamais à la frappe. Une frappe coûte la construction d'un `KeyBinding` et une recherche dans un dictionnaire (≈ 0,7 µs en Debug, mesuré par un test). Les lettres sont stockées par caractère tapé (`charactersIgnoringModifiers`, donc valable en AZERTY), les touches spéciales (flèches, ⌫, ⌦, Échap, Espace, ↩, pages, F1-F12…) par code.

**Répétition** : `ShortcutMap.decide` est le seul point de décision, pour la visionneuse, la comparaison et le menu. `NSEvent.isARepeat` sur une commande sans `repeats` est absorbé, quelle que soit la touche : maintenir une touche de suppression ne supprime qu'une photo, une bascule ne bascule qu'une fois. Seule la navigation se répète.

**Menus** : la vue répond à toutes les touches d'une commande, le menu en affiche une. Une touche sans modificateur n'entre jamais dans le menu pour une commande destructive. Les éléments de menu des commandes photo sont grisés quand la visionneuse n'a pas le clavier : une touche tapée dans les réglages n'atteint jamais une photo. Seul « Annuler la suppression » reste actif partout (il ne fait que restaurer, y compris depuis l'historique). ⌘Q, ⌘W, ⌘O, ⌘, et ⌘Y (historique) sont réservés au menu de l'app.

**Conflits** : dans les réglages, une touche déjà prise est signalée (« déjà utilisée par… ») ; « Remplacer » la retire à l'autre commande, « Annuler » ne change rien. ↺ rétablit les touches par défaut d'une commande, sauf celles qu'une autre commande a prises depuis (signalé) ; « Tout rétablir » revient aux valeurs par défaut.

**Capture** : `KeyRecorder` pose un moniteur local `NSEvent` le temps d'une capture, qui avale les frappes de la fenêtre de réglages avant les menus. Une frappe dans une autre fenêtre, ou la perte du clavier par les réglages, annule la capture et la frappe suit son chemin normal. Échap seul annule (convention macOS) ; ⌫ s'enregistre comme une touche.

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
- ⌘Z après l'ouverture d'un autre dossier : restauré sur disque, absent de la nouvelle liste ;
- restauration refusée (chemin occupé, accès refusé) puis retentée ; autre fichier à l'URL en corbeille : refus ;
- journal interrompu entre déplacement et écriture : entrée tranchée par le disque ou « à vérifier » ;
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

135 tests passent après fusion de `main` (raccourcis configurables, bande et comparaison). Council GPT-6.1 Sol medium : APPROVE sur `db5d743`, seconde instance du même modèle autorisée explicitement. A rejoint `ShortcutAction` ; la comparaison conserve son zoom synchronisé et ignorait alors cette action AF (depuis, A y centre chaque photo sur son propre point AF, voir Comparaison).

Sur les 403 ARW actuellement présents dans `~/Pictures`, `--verify-af` retrouve 403 positions (68 au centre), aucune incohérence avec l’extent Apple. Comparaison séparée avec ExifTool : aucun écart de position, orientation ou mode AF.

Bench Release sur ces 403 fichiers : après une première passe perturbée (saut sans cache p95 1059 ms), une passe de référence `main`, puis une seconde passe AF donnent respectivement un p99 de navigation à 1 photo/s de 5,5 et 5,6 ms, touche maintenue 2,2 et 2,1 ms, saut sans cache p95 613 et 593 ms. Aucun écran vide ; arrivées S/F 100 % à 1 et 3 photos/s. La seconde passe AF démarre en 378 ms et tient 1762 Mo au repos. Les premiers lancements des deux binaires neufs ont pris environ 20 s ; un contrôle de lancement AF suivant prend 403 ms. Ces délais initiaux restent inexpliqués et ne sont pas spécifiques à la branche. Mesures indicatives sur une machine partagée ; aucune régression reproductible identifiée.

### Bande étirable et aimantée à la fenêtre (2026-11-13)

`--bench` Release, 133 ARW sur SSD interne, machine partagée, un passage chacun en alternant : `main`, la branche avec la bande tenue par la fenêtre et centrée (`-stripPlacement` en argument, sans toucher aux réglages), puis `main`. Navigation à 1 photo/s p99 5,1 / 7,0 / 6,5 ms (une première passe de la branche : 3,9 ms), à 3 photos/s 2,7 / 2,2 / 2,4 ms, touche maintenue 6,1 / 3,3 / 3,8 ms, suppression 19,8 / 6,3 / 23,6 ms ; arrivées S/F 100 % et aucun écran vide partout. Objectif de 8 ms tenu ; écarts dans le bruit d'un passage unique.

Avec la hauteur et la règle de focus, deux paires alternées (branche avec une bande de 1100 × 162 pt tenue sous la fenêtre, vignettes de 440 px, puis `main`), machine chargée par d'autres compilations : navigation à 1 photo/s p99 11,3 et 8,9 ms contre 9,1 et 8,8 ms pour `main` (n = 30, le p99 est le pire tirage ; `main` dépasse aussi 8 ms dans ces conditions), 3 photos/s 3,1 et 3,1 contre 3,2 et 3,1 ms, touche maintenue 4,9 et 3,3 contre 4,3 et 2,6 ms, suppression 9,6 et 3,0 contre 3,6 et 2,8 ms ; aucun écran vide, arrivées S/F 100 %. Pas d'écart reproductible ; à refaire sur machine calme.
