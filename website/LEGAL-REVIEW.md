# Footer et informations avant publication

Travail du 15 novembre 2026, dans le worktree `t3/footer-mentions-legales`.
Site importé depuis le worktree `t3-fbf49945-b6d16c16edd90725`, sans modification de celui-ci. Dépendances, sorties Astro et rapports de tests exclus de l’import. Aucune publication.

## Obligations vérifiées sur les sources officielles

- [LCEN, article 1-1, version en vigueur](https://www.legifrance.gouv.fr/codes/article_lc/LEGIARTI000049568614/) : identité (nom, prénoms, domicile, téléphone pour une personne physique), direction de publication, nom/raison sociale, adresse et téléphone de l’hébergeur ; identité et adresse des autres prestataires stockant les données, le cas échéant. Le II permet à un éditeur **non professionnel** de ne publier que le nom/raison sociale et l’adresse de l’hébergeur pour préserver son anonymat, à condition d’avoir communiqué les éléments d’identification personnelle du I à celui-ci. Ne pas publier l’adresse privée sans décision de l’éditeur. Le caractère open-source ne dispense pas des mentions légales et ne prouve pas le statut non professionnel.
- [Service Public : mentions d’un site d’entreprise](https://entreprendre.service-public.gouv.fr/vosdroits/F37351) : dispositions supplémentaires à examiner uniquement si l’éditeur exerce une activité professionnelle. Le site examiné n’a pas de vente ni commande : aucune CGV commerciale fabriquée, aucun numéro RCS/TVA inventé. Réexaminer si le modèle change.
- [CNIL : exemples de mentions d’information](https://www.cnil.fr/fr/rgpd-exemples-de-mentions-dinformation) : informer sur le responsable, les finalités, bases légales, destinataires, durées, droits et leur exercice et transferts éventuels selon les traitements réels. Aucun hébergeur déterminé : ne pas promettre l’absence de journaux ou de collecte d’IP.
- [CNIL : cookies, que dit la loi ?](https://www.cnil.fr/fr/cookies-et-autres-traceurs/que-dit-la-loi) : consentement préalable pour les traceurs non exemptés. Mise à jour du 16/11/2026 : ajout d’Umami auto-hébergé sur ibox, sans cookies, avec Do Not Track et exclusion des paramètres et fragments. La page de confidentialité décrit cette mesure ; la revue initiale sans analytics est donc dépassée. Pas de bandeau ajouté. Revérifier l’hébergeur/CDN avant publication et tout ajout de traceur.

Pages préparatoires en `noindex, nofollow` ; ne pas les considérer comme des mentions complètes. Enlever le bandeau préparatoire et `draft` dans LegalLayout seulement après validation et complément des informations.

## Informations manquantes

Configuration publique centralisée : `src/config/legal.ts`. Les champs non établis restent à `null` et sont rendus « À compléter avant publication ».

1. Confirmer statut de l’éditeur et choix d’identification publique ou d’anonymat LCEN. Renseigner l’identité et la direction de publication si identification publique ; en cas d’anonymat, indiquer uniquement les mentions publiques pertinentes, vérifier les conditions et transmettre l’identité en privé à l’hébergeur (jamais dans ce dépôt).
2. Établir l’hébergement réel du **site**, ses coordonnées légales et les éventuels autres prestataires de stockage. Le repo mentionne GitHub pour le code et les releases, pas un hébergement du site. La recherche ciblée BetterView dans README et fiches machines de `~/code/infra` ne fournit que des notes macOS relatives aux releases/Sparkle : aucune preuve de l’hébergeur web. Aucun changement infra.
3. Fournir un contact valide ; préciser responsable des traitements, journaux serveur/CDN, finalités, bases légales, destinataires, durées, transferts et modalités d’exercice des droits. Adapter les paragraphes de confidentialité aux réponses.
4. Décider et versionner les licences du logiciel et du site : aucun LICENSE/COPYING identifié dans le dépôt. Ne pas afficher MIT, « libre » ou une autorisation de réutilisation implicite. Vérifier séparément les droits des images/icône ; liens de provenance disponibles dans les mentions, sans inventer les noms des photographes.

## Résultat et contrôles

Footer commun aux pages d’accueil, essai, comparaison et documents. Navigation sémantique, focus existant, retours à la ligne mobiles ; palette et police existantes conservées. Pages `/mentions-legales/` et `/confidentialite/`, liens internes préfixés avec la base Astro. Aucun script tiers ajouté.

Validation exécutée : builds réussis pour `/` et `/BetterView/`, liens locaux du footer et des documents vérifiés sur les cinq pages pour ces deux bases, 18 tests existants réussis et formatage validé. Build final remis à la racine. Voir les commandes reproductibles dans README. Les liens externes sont des références et destinations officielles consultées, pas une garantie de disponibilité future. Les tests ne constituent pas une validation juridique ni une revue visuelle navigateur.

## Informations confirmées le 16 novembre 2026

- Éditeur : 23octets, SASU, SIREN 984340125 ; adresse publique et direction de publication Yohan Gouiran fournies par l’éditeur. Identité et adresse corroborées par https://annuaire-entreprises.data.gouv.fr/entreprise/23octets-984340125.
- Contact : contact@23o.dev.
- Licence choisie : GPLv3 pour le code original du logiciel et du site, matérialisée par LICENSE (GPL-3.0-only). Les mentions historiques ci-dessus sur l’absence de licence décrivent l’état avant ce choix.
- Hébergement prévu : Hetzner en Allemagne ; Umami déjà intégré via stats.yohan.one, suivi activé uniquement pour PUBLIC_UMAMI_DOMAINS.
- Capital social confirmé par l’éditeur : 1 000 €. Domaine public : https://betterview.photos. Aucun téléphone professionnel disponible à ce jour ; aucun numéro personnel ajouté.
- À compléter : immatriculation RCS, téléphone de l’éditeur et TVA si applicable ; machine du site ; configuration réelle des journaux, durées, base légale et modalités du traitement d’audience. Les pages restent préparatoires.
- Icône déclarée générée par IA ; aucune garantie de droits exclusifs affirmée.

La configuration Umami est menée en parallèle par Yohan : ne pas la modifier dans ce chantier de mentions légales.
