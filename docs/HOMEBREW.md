# Distribution Homebrew

BetterView utilise le tap `rocktane/homebrew-tap`, comme BetterBattery. Une fois la première release universelle publiée et le workflow Homebrew intégré sur `main` :

```sh
brew install --cask rocktane/tap/betterview
```

Le cask accepte les Mac Intel et Apple Silicon, sous macOS 14 (Sonoma) ou plus récent. Homebrew installe le bundle compilé : Xcode et XcodeGen ne sont pas nécessaires chez l'utilisateur.

## Publication

Le workflow `.github/workflows/homebrew.yml` complète le workflow de publication Sparkle `Release`. Il ne construit pas de seconde archive. Il attend une release stable `vMAJEUR.MINEUR.CORRECTIF` contenant `BetterView-MAJEUR.MINEUR.CORRECTIF.zip` et `SHA256SUMS.txt`.

Après un workflow `Release` réussi ou une publication manuelle, il récupère la dernière release stable, vérifie le SHA256, l'identité et la version du bundle, macOS 14 minimum, les deux architectures et la signature du bundle. Il met ensuite à jour `Casks/betterview.rb` dans le tap. Les préversions ne sont jamais distribuées par ce cask. Une relance utilise toujours la dernière release stable pour éviter de revenir à une ancienne version.

Les releases publiées avec `GITHUB_TOKEN` ne déclenchent pas d'autre workflow via l'événement `release` : le déclencheur `workflow_run` est donc nécessaire pour le workflow Sparkle. Conserver le nom `Release` de ce workflow, ou adapter la référence dans `homebrew.yml`.

Le secret Actions `TAP_DEPLOY_KEY` doit contenir une clé SSH dédiée dont la partie publique est une deploy key avec accès en écriture à `rocktane/homebrew-tap`. La clé Sparkle reste utilisée uniquement par le workflow de publication de l'app.

Pour reprendre un échec de mise à jour du tap après publication : lancer **Actions > Update Homebrew > Run workflow**. Ne pas reconstruire ni remplacer l'archive publiée. Si un autre projet a modifié le tap entre le checkout et le push, relancer cette seule mise à jour.

Homebrew ne remplace pas la notarisation Apple : la signature ad hoc actuelle ne lève pas Gatekeeper. Les mises à jour proposées dans l'app par Sparkle et celles proposées par Homebrew restent deux chemins de mise à jour ; le cask ne déclare pas `auto_updates`, afin que `brew upgrade --cask` continue de proposer les nouvelles versions.

## État initial

La chaîne nécessite l'intégration du travail Sparkle et une première release publique avant que la commande d'installation fonctionne. Le workflow refuse une archive ne contenant pas à la fois `arm64` et `x86_64` ; la vérification des architectures prouve leur présence, pas le fonctionnement de l'app sur un vrai Mac Intel.
