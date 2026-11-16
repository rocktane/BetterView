# Sources des visuels PhotoBenefits

Recherche et extraction des pages publiques effectuées avec Firecrawl les 15 et 16 novembre 2026. Les trois photos sont libres d’utilisation selon la [licence Unsplash](https://unsplash.com/license). Les WebP sont servis localement ; aucune requête distante n’est nécessaire à l’affichage.

## C — Deux cadrages de la même photo

- Crédit et page : [A view of a mountain through some trees — Unsplash](https://unsplash.com/photos/a-view-of-a-mountain-through-some-trees-o9jGHeDzULg).
- Original : <https://images.unsplash.com/photo-1694434136676-249cd196d8a6>.
- Fichier source local : `public/images/portrait-3-full.webp`, 4000 × 6000 px.
- `compare-wide-{400,800}.webp` : recadrage `3200 × 4000 + 400 + 600`.
- `compare-close-{400,800}.webp` : recadrage plus resserré `2200 × 2750 + 900 + 1500` dans **le même fichier**.
- Les deux images sont donc deux cadrages d’un même paysage, et non deux photos sans rapport ni une prétendue rafale authentique.

## Z — Détail non humain

- Crédit et page : [Landscape photo of mountain — Unsplash](https://unsplash.com/photos/landscape-photo-of-mountain-Lu2SWEyuLkU).
- Original : <https://images.unsplash.com/photo-1529840180348-efd52969a4ce>.
- Fichier source local : `public/images/portrait-2-full.webp`, 3264 × 4896 px.
- `benefit-detail-mountain-{600,1200}.webp` : recadrage 3:2 sur la paroi rocheuse, déjà disponible localement.
- Ce paysage est distinct de la photo utilisée pour la comparaison C.

## A — Nouveau portrait et cercle sur l’œil

- Crédit : **Amanda Dalbjörn** ([@amandadalbjorn](https://unsplash.com/@amandadalbjorn)).
- Page : [Close-up photo of persons eye](https://unsplash.com/photos/close-up-photo-of-persons-eye-fvInY-Gh7sc).
- Original : <https://images.unsplash.com/photo-1516220362602-dba5272034e7>.
- Source téléchargée : 2400 × 1600 px.
- `focus-{600,1200}.webp` : redimensionnement 3:2 complet, sans changement de cadrage ni retouche générative.
- Inspection du WebP final 1200 × 800 : centre de la pupille à **(461, 346)**. Le cercle est positionné à `left: 38.4 %; top: 43.3 %`, avec un diamètre de 144 px à cette taille pour entourer l’iris et non le visage.

Tous les nouveaux recadrages et exports ont été réalisés en WebP qualité 88, méthode 6. Les variantes responsives conservent exactement le même cadrage à chaque largeur.
