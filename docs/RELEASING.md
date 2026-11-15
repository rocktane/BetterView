# Publier BetterView

## Distribution

BetterView est distribuée hors App Store, sans certificat Apple ni notarisation. La signature locale ad hoc permet de vérifier l'intégrité du bundle, mais ne lève pas Gatekeeper. L'autorisation initiale est décrite dans le README. Le hardened runtime reste actif ; l'entitlement de désactivation de la validation des bibliothèques permet de charger Sparkle avec une signature ad hoc.

Sparkle 2.10.1 est intégré via Swift Package Manager, avec une version exacte dans `project.yml`. Les ZIP sont universels (arm64 et x86_64), pour macOS 14 et plus récent.

L'app consulte :

```
https://github.com/rocktane/BetterView/releases/latest/download/appcast.xml
```

Chaque release stable héberge son ZIP, son `appcast.xml` signé au niveau de l'archive et `SHA256SUMS.txt`. Le flux ne contient que cette version : les utilisateurs peuvent passer directement de n'importe quelle ancienne version à la dernière. Aucun serveur ni GitHub Pages n'est nécessaire. Avant la première publication, l'URL du flux renvoie 404 ; la vérification manuelle affiche donc une erreur.

## Publier une version

1. Modifier `MARKETING_VERSION` et `CURRENT_PROJECT_VERSION` dans `project.yml`, avec la même version à trois nombres, par exemple `1.0.1`. Toujours augmenter cette version : Sparkle utilise `CFBundleVersion` pour comparer les mises à jour.
2. Intégrer les changements sur `main`, puis mettre à jour l'app installée avec `scripts/install.sh`, conformément à `AGENTS.md`.
3. Créer le tag sur le commit intégré correspondant et le pousser :

   ```sh
   git tag v1.0.1 <commit-intégré>
   git push origin v1.0.1
   ```

Le workflow `.github/workflows/release.yml` exécute les tests, construit le ZIP universel, génère l'appcast, vérifie cryptographiquement la signature avec la clé publique embarquée et publie la release avec des notes générées par GitHub. Il refuse un tag qui ne correspond pas aux deux versions du bundle ou une release qui existe déjà.

Pour reprendre un échec avant publication, relancer le workflow pour le même tag, ou utiliser **Actions > Release > Run workflow** et renseigner ce tag existant. Ne pas déplacer un tag public ou remplacer ses archives. Si le code doit changer, publier une nouvelle version.

Les tags acceptés sont uniquement `vMAJEUR.MINEUR.CORRECTIF`, sans suffixe de préversion. Le flux vise la dernière release stable ; ne pas déclarer une ancienne version comme dernière release.

## Préparer une archive en local, sans publier

```sh
scripts/release.sh v1.0.0
```

Les deux versions de `project.yml` doivent correspondre au tag demandé. Les fichiers sont placés dans `build/release/v1.0.0/`. Le script refuse de remplacer un dossier de sortie existant. Il ne crée ni tag ni release et ne modifie pas `/Applications`.

## Clé Sparkle

La clé privée a été générée avec `generate_keys --account com.yohan.betterview`. Elle est conservée dans le Trousseau de session du Mac ; la clé publique est versionnée dans `Resources/Info.plist` (`SUPublicEDKey`). Le secret GitHub Actions `SPARKLE_PRIVATE_KEY` contient la même clé privée exportée. Aucun certificat Apple n'est nécessaire pour cette signature.

Ne jamais versionner ou afficher la clé privée. Sans certificat Developer ID, perdre cette clé empêche les utilisateurs existants de recevoir les mises à jour avec une nouvelle clé : conserver une sauvegarde sécurisée du Trousseau ou un export chiffré.

Après résolution des dépendances, les outils sont dans :

```
build/SourcePackages/artifacts/sparkle/Sparkle/bin/
```

Pour réinstaller le secret GitHub depuis ce Mac : exporter la clé avec `generate_keys --account com.yohan.betterview -x <fichier-privé>`, puis exécuter `gh secret set SPARKLE_PRIVATE_KEY --repo rocktane/BetterView < <fichier-privé>`. Utiliser un dossier temporaire privé et supprimer l'export immédiatement après. Le workflow transmet le secret via stdin à `generate_appcast`.

## Vérifier une vraie mise à jour

Avant de promettre le fonctionnement complet aux utilisateurs, installer une première version distribuée dans `/Applications`, l'autoriser selon le README, publier une version supérieure puis choisir **BetterView > Rechercher les mises à jour…**. Vérifier le téléchargement, l'installation, le redémarrage et la nouvelle version. Cette vérification nécessite deux releases accessibles ; une compilation et une signature valides ne prouvent pas à elles seules le remplacement de l'app par Sparkle.
