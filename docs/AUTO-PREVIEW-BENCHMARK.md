# Aperçu Auto : comportement et mesures

16 novembre 2026. Carte **Amélioration auto** sous les informations en vue simple. Après calcul, un séparateur vertical déplaçable compare l’original (gauche) et Auto (droite), avec zoom et déplacement synchronisés. **Espace** bascule entre les deux versions en plein cadre ; le bouton rétablit le séparateur sans recalcul. S conserve la sélection ; Espace ne sélectionne plus. Développement RAW via `CIRAWFilter`, puis chaîne `CIImage.autoAdjustmentFilters` (yeux rouges exclus), puis rendu Display P3. Aucun export ni enregistrement de recette ou de pixels corrigés. L’aperçu est libéré à la navigation, à l’entrée en comparaison ou sous pression mémoire ; une génération empêche les résultats tardifs de remplacer une autre photo. Un seul calcul Auto simultané par fenêtre.

Le résultat est limité à la taille écran, au maximum 2 560 pixels de côté, même en zoom. Il sert à juger le potentiel tonal/couleur avant Lightroom, pas le détail à 100 %. L’original est conservé par référence pendant la comparaison ; un autre clic sur le bouton revient au séparateur sans recalcul. Pendant Auto, les nouveaux rendus fullres et le remplissage du disque en arrière-plan sont suspendus ; les travaux déjà lancés peuvent finir, et le préchargement écran reste actif. Le calcul Auto tourne hors thread principal et partage le contexte Core Image existant. Il n’est pas interrompu au milieu d’un traitement GPU : annuler invalide son résultat.

## Protocole reproductible

MacBook Pro M1 Pro, CPU 8 cœurs/GPU 14 cœurs, 16 Go, macOS 27.0.1 ; Xcode 27.2, build Release arm64. Cinq RAW Sony A7C04171–A7C04175 du dossier local « À retoucher », 3 passages, soit 15 rendus par configuration. Résultat paysage 2 560 × 1 707 ou 1 280 × 854 pixels. Même fonction de décodage/rendu que le bouton ; original = sans chaîne Auto.

Processus neuf pour chaque configuration, exécution séquentielle sans compilation concurrente lors du relevé final. Chronométrage monotone jusqu’au verrouillage de la surface (attente de fin GPU incluse). Les temps incluent lecture, développement RAW, analyse éventuelle et rendu, mais pas le clic ni l’affichage AppKit. « Premier » signifie premier appel dans le processus, pas disque froid ni caches système purgés. Statistiques chaudes : les 14 appels suivants ; p95 peu représentatif avec ce petit échantillon.

| Mesure observée | Original 2560 | Auto 2560 | Auto 1280 |
|---|---:|---:|---:|
| Premier appel | 612 ms | 1 032 ms | 1 008 ms |
| Médiane des 14 suivants | 256 ms | 584 ms | 599 ms |
| p95 des 14 suivants | 307 ms | 606 ms | 733 ms |
| Empreinte mémoire maximale | 609 Mo | 652 Mo | 477 Mo |
| RSS maximal | 149 Mo | 193 Mo | 192 Mo |
| Surface corrigée conservée | — | 17,5 Mo | 4,4 Mo |
| Temps CPU total utilisateur + système (15 rendus) | 3,56 s | 7,38 s | 7,39 s |

Mo décimaux. Empreinte et RSS proviennent de `/usr/bin/time -l`, mesures du **processus de benchmark**, pas de l’application complète avec ses caches. La RSS seule sous-estime les allocations imputées au processus, notamment graphiques : privilégier l’empreinte. Les pics ne se produisent pas nécessairement au même moment ; leur différence n’est pas une mesure précise du surcoût instantané.

Auto 2560 utilise ainsi environ 0,49 seconde CPU par aperçu en moyenne sur ce lot (quotient du total, initialisation comprise). Le GPU participe aussi ; son taux d’occupation, la puissance et la batterie n’ont pas été mesurés. Aucune conversion en pourcentage global CPU/GPU n’est revendiquée.

Lors d’un premier essai exploratoire, avec compilation concurrente, Auto avait pris 2,99 s au premier appel puis 385 ms de médiane ; ces chiffres montrent la variabilité et ne remplacent pas le relevé final. Retenir **environ 0,4–0,6 s à chaud sur ces fichiers**, avec un premier appel pouvant prendre plusieurs secondes. Réduire à 1280 a réduit le pic mémoire, sans accélération observée ici : le coût ne dépend pas uniquement des pixels de sortie.

Le benchmark ne comprend ni les caches de navigation de BetterView, ni une charge GPU concurrente représentative, ni d’autres boîtiers. Il ne garantit donc pas un plafond mémoire pour l’app entière, ni la même latence en navigation. L’aperçu conservé ajoute une surface de 17,5 Mo sur ces photos ; Core Image garde aussi temporairement des intermédiaires.

## Relancer

Après génération du projet et compilation Release :

```sh
/usr/bin/time -l <BetterView.app>/Contents/MacOS/BetterView --bench-auto '/chemin/RAW'
```

Ajouter `--original` pour le témoin, `--small` pour 1280. Le mode benchmark lit les cinq premiers `.arw` triés du dossier et ne touche pas au cache utilisateur. Les journaux du relevé final sont dans [benchmarks-auto](benchmarks-auto/).

Validation initiale : build Release arm64 réussi ; suite Debug, **318 tests réussis, 1 ignoré, 0 échec**. Quatre nouveaux tests couvrent retour à l’original sans modification du fichier, navigation avant résultat, annulation pendant calcul et échec du rendu. Aucun remplacement de l’application installée n’a été effectué.

Validation du séparateur : build Release arm64 réussi ; **322 tests réussis, 1 ignoré, 0 échec**. Les tests supplémentaires vérifient l’alignement original/Auto pendant zoom, déplacement et redimensionnement, le retour au séparateur sans recalcul, la carte sous les informations et la migration d’Espace depuis l’ancien raccourci de sélection.
