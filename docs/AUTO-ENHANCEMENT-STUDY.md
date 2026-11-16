# Bouton Auto : étude BetterView

État vérifié le 15 novembre 2026, sources primaires consultées via Firecrawl. Recommandation : **Auto Core Image, local, réversible**, puis IA spécialisée seulement si des essais démontrent un gain. Aucune implémentation ni mesure nouvelle ; les coûts ci-dessous sont des estimations de jours de développement pour une personne connaissant Swift/macOS.

## Contexte réel

BetterView cible macOS 14 (`project.yml`). `Decoders.swift` extrait d’abord le JPEG embarqué (chemin Sony dédié), puis développe le RAW avec `CIRAWFilter` : réduction via `scaleFactor` pour l’écran, taille native au zoom. Le `CIContext` partagé travaille en RGBAh ; la sortie est une `IOSurface` BGRA 8 bits Display P3 (`Frame.swift`), affichée par Core Animation (`ViewerView.swift`). Il faut corriger **avant** cette sortie pour préserver la latitude RAW.

`Pipeline.swift` exécute les traitements hors thread principal, réserve de la capacité au visible, limite le GPU à 2–3 travaux et sérialise les rendus fullres. `FrameCache.swift` sépare preview/screen/full ; `DiskCache.swift` conserve des JPEG écran qualité 0,9. Les clés identifient fichier/révision/taille/version de rendu, mais aucune recette de retouche. Aucun système de retouche/export utilisateur trouvé : le JPEG du cache n’est pas un export.

## Options comparées

| Solution | Apport et limites | Intégration estimée, entretien |
|---|---|---|
| Core Image Auto + RAW | Déjà présent, hors ligne, sans poids supplémentaires ; résultat à valider, aucune garantie d’égaler Photos | 2–4 j prototype ; 8–15 j MVP durable ; entretien faible à modéré, régressions OS/caméras |
| Apple Photos | PhotoKit/extension pour **nos** traitements ; moteur Auto interne non exposé dans les API consultées | 5–10 j additionnels pour bibliothèque/extension ; permissions, cycles Photos et formats à maintenir |
| Open source | Contrôle accru, mais une bibliothèque de filtres n’est pas une décision Auto | MetalPetal 5–10 j de socle, algorithme en plus ; autre développeur RAW 15–30 j ; entretien moyen/élevé |
| Core ML local | Débruitage/restauration ciblés ; conversion, qualité et mémoire à prouver | 3–7 j faisabilité ; 20–40 j intégration robuste d’un modèle existant, hors entraînement ; entretien élevé |
| Apple Intelligence | Capacités système conditionnelles ; pas de remplacement local garanti d’Auto | 2–5 j exploration ; produit génératif distinct, dépendances OS/service |

Ces postes ne s’additionnent pas tous. Le MVP estimé inclut recettes, cache, UI, persistance et export simple ; l’extension Photos est facultative.

### Core Image : meilleur premier choix

[`autoAdjustmentFilters`](https://developer.apple.com/documentation/coreimage/ciimage/autoadjustmentfilters()) analyse l’image et retourne des filtres configurés à appliquer dans l’ordre. Le [guide Apple](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/CoreImaging/ci_autoadjustment/ci_autoadjustmentSAVE.html) décrit courbe tonale, ombres, vibrance, équilibre des visages et yeux rouges, et permet de conserver noms/paramètres pour éviter une nouvelle analyse. API disponible depuis macOS 10.8, compatible avec la cible actuelle.

[`CIRAWFilter`](https://developer.apple.com/documentation/coreimage/cirawfilter) fournit exposition, balance des blancs, bruit et corrections optiques selon support. Ce sont des contrôles, pas un jugement esthétique automatique. Éviter d’empiler deux corrections tonales excessives ; vérifier peaux, contre-jours, nuit et lumières colorées. Ne pas analyser le JPEG boîtier puis appliquer aveuglément ses réglages au RAW, dont le rendu diffère.

### Photos : intégration permise, moteur privé à exclure

[PhotoKit](https://developer.apple.com/documentation/photokit/editing-asset-content) permet de lire un asset autorisé et de soumettre notre rendu avec `PHAdjustmentData`. Une [extension Photos](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Photos.html) expose notre éditeur dans Photos ; elle ne fournit pas ses outils internes. Aucun appel public identifié pour « appliquer Auto de Photos » ou Clean Up à un fichier arbitraire. Ne pas dépendre des frameworks privés, de données de réglage Apple opaques ou d’automatisation UI fragile. Photos conserverait l’original ; BetterView reste actuellement orienté fichiers.

### Open source et modèles

[MetalPetal](https://github.com/MetalPetal/MetalPetal#license), natif Metal/Swift, est MIT : conserver les notices ; ses exemples ont une licence séparée. Il ajouterait un second graphe GPU sans fournir Auto. [LibRaw LGPL 2.1](https://github.com/LibRaw/LibRaw/blob/master/LICENSE.LGPL) ajouterait un développeur RAW, pas un moteur esthétique ; distribution/reliaison et dépendances doivent être vérifiées avant choix.

[Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) vise restauration/superrésolution, pas exposition/couleur ; [code BSD-3-Clause](https://github.com/xinntao/Real-ESRGAN/blob/master/LICENSE). Auditer séparément poids exacts, provenance, dépendances et droit de redistribution. La distribution Python n’est pas une intégration Swift : conversion Core ML ou runtime supplémentaire. Le projet signale des incohérences possibles entre tuiles.

[Core ML](https://developer.apple.com/documentation/coreml) exécute localement sur les dispositifs compatibles CPU/GPU/Neural Engine selon modèle ; l’accélération effective reste à profiler. Taille et RAM dépendent du modèle : **calcul illustratif**, 10 millions de paramètres FP16 ≈20 Mo de poids, hors activations/compilation ; modèles génératifs potentiellement de plusieurs Go. Hors ligne après installation/téléchargement, avec coût disque et premier chargement. Risques : détails inventés, textures lissées, couleurs modifiées.

### Apple Intelligence : disponibilité réelle

[Foundation Models](https://developer.apple.com/documentation/foundationmodels) génère du texte et propose désormais aussi de la compréhension d’images : comprendre une photo ne produit pas ses pixels corrigés. [Image Playground](https://developer.apple.com/documentation/imageplayground), initialement macOS 15.1+, possède des capacités variables par version. Les [nouveautés WWDC26](https://developer.apple.com/videos/play/wwdc2026/375/) permettent transformation générative via interface système et Private Cloud Compute, avec quotas ; `ImageCreator` est déprécié. Vérifier disponibilité à l’exécution, modèles téléchargés et [conditions appareil/langue/région](https://support.apple.com/en-us/121115). Rien de cela ne garantit correction fidèle fullres, fonctionnement offline ou compatibilité macOS 14.

## MVP, performances et preuve attendue

Analyser une version réduite du **développement RAW**, figer une recette versionnée, puis réappliquer aux rendus écran/fullres ; gérer coordonnées des éventuels filtres spatiaux. Bouton avant/après, annulation, original intact ; recette persistée séparément, export explicite depuis l’original avec profil couleur/métadonnées maîtrisés. Ne jamais exporter le cache JPEG.

Ajouter recette/version aux clés mémoire/disque, rejeter les résultats devenus périmés. Priorité au visible ; aucun Auto de dossier en arrière-plan par défaut. Réutiliser le contexte, limiter concurrence et mémoire plutôt que doubler tous les caches.

**Mesures historiques consignées dans le code**, non reproduites : cache disque ≈25 ms contre RAW écran ≈270 ms ; pool Core Image ≈1 Go écran/2,5 Go fullres. Elles ne prédisent pas Auto. **Calcul** : une surface 24 MP BGRA coûte ≈96 Mo, RGBAh ≈192 Mo, hors intermédiaires ; mémoire unifiée ne signifie pas mémoire gratuite.

Avant engagement : comparer original/Auto sur RAW variés, mesurer froid/chaud p50/p95, clic→affichage, export fullres, pic mémoire et navigation concurrente sur Apple Silicon 8/16 Go. Aucune latence Auto annoncée sans bench. Ajouter l’IA uniquement si ce corpus démontre un bénéfice ciblé supérieur au coût et aux artefacts.
