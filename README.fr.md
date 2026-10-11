# AI Prime Cursor Manager (Windows) — expérimental

[English](README.md) | [Eesti](README.et.md) | Français | [Deutsch](README.de.md) | [فارسی](README.fa.md)

**Statut : expérimental / alpha.** Ce projet est un outil Windows destiné à tester un pont local authentifié et compatible avec l’API OpenAI entre Cursor et AI Prime Tech. Le pont et les tests statiques du contrat du tunnel passent dans l’environnement de développement actuel, mais l’interface WPF complète et un véritable Cloudflare Quick Tunnel n’ont pas été validés de bout en bout sur une installation Windows propre. Ne considérez pas le code source actuel comme une version prête pour la production.

## Fonctionnalités

- Tableau de bord PowerShell/WPF pour tester une clé API AI Prime Tech et récupérer les identifiants des modèles accessibles avec cette clé.
- Pont Node.js local à l’écoute sur \`127.0.0.1\`, exposant à Cursor un alias de modèle configurable et transmettant les requêtes à AI Prime Tech.
- Authentification par jeton Bearer entre Cursor et le pont local. Cursor doit recevoir la clé du pont, et non la clé API AI Prime Tech.
- Commandes du pont, journaux, paramètres de connexion Cursor, sélection du modèle et gestion expérimentale de Cloudflare Quick Tunnel.
- Tests hors ligne utilisant un serveur amont simulé local, sans identifiants API réels.

## Langues de l’interface

L’interface WPF propose un sélecteur de langue dans le coin supérieur droit. Les langues prises en charge sont **l’anglais (par défaut), l’estonien, le français et l’allemand**. Le changement de langue met à jour les libellés, onglets, boutons, info-bulles, l’avis de sécurité et les messages d’état traduits. La langue choisie est enregistrée dans les paramètres propres à l’utilisateur et restaurée au prochain lancement.

Les identifiants techniques, les ID de modèles, les URL et les réponses du fournisseur restent dans leur forme d’origine afin de pouvoir être copiés exactement.

## Limites importantes

- **Limite de l’Explore intégré à Cursor :** ce projet ne peut pas contourner les restrictions du produit Cursor. Selon la version et la configuration de Cursor, un modèle personnalisé BYOK peut ne pas être sélectionnable séparément pour l’Explore Subagent intégré.
- **Cursor distant et localhost :** une requête distante ou cloud ne peut pas atteindre directement le \`127.0.0.1\` de votre ordinateur. L’onglet Quick Tunnel expérimental fournit une URL HTTPS publique temporaire pour les tests. Gardez l’authentification activée et arrêtez le tunnel après utilisation. N’utilisez pas de pont public sans authentification.
- **Validation Windows :** cet environnement de développement ne peut pas exécuter WPF. Avant une version stable, un testeur Windows doit vérifier le démarrage réel, le démarrage/l’arrêt du pont, la progression du téléchargement et Quick Tunnel sur une vraie machine Windows.
- Le fichier EXE précompilé n’est volontairement pas suivi dans le dépôt source tant qu’il n’a pas été vérifié par rapport au code actuel. Utilisez plutôt le lanceur PowerShell depuis le dossier entièrement extrait.
- Les prompts et le code transmis par le pont sont traités par AI Prime Tech. N’envoyez pas de code confidentiel sauf si vos règles l’autorisent.

## Prérequis

- Windows 10/11
- Windows PowerShell 5.1 ou plus récent avec WPF
- Node.js 20 ou plus récent accessible via \`PATH\`
- Clé API AI Prime Tech active avec accès au modèle choisi

## Exécuter depuis les sources

1. Téléchargez ou clonez ce dépôt et extrayez-le dans un dossier normal (pas directement dans le ZIP).
2. Lancez \`Start-AI-Prime-Cursor-Manager.bat\`.
3. Si le démarrage échoue, lancez \`Start-AI-Prime-Cursor-Manager-Diagnostics.bat\` et ne partagez que le texte de l’erreur, jamais les clés ni les URL de tunnel.
4. Dans Dashboard, saisissez la clé API AI Prime Tech et cliquez sur **Refresh model catalog**.
5. Sélectionnez un modèle et lancez **Test selected model** avant une session plus longue.
6. Démarrez le pont local. Dans un profil Cursor distinct, configurez **Use OpenAI API Key** et **Override OpenAI Base URL** avec les valeurs affichées dans Cursor Setup. Utilisez la *clé du pont local*, pas la clé AI Prime Tech.

### Exécuter les tests hors ligne

Avec Node.js 20 ou plus récent :

\`\`\`powershell
npm test
npm run check
\`\`\`

Vous pouvez aussi double-cliquer sur \`Run-Bridge-Smoke-Tests.bat\` sous Windows. Les tests utilisent un serveur amont simulé et n’appellent pas AI Prime Tech.

## Sécurité

- Ne committez jamais de clés API, clés du pont, jetons d’accès, journaux, fichiers de paramètres ou URL Cloudflare Tunnel.
- Le pont doit écouter uniquement sur \`127.0.0.1\` et ses points de terminaison API doivent exiger la clé Bearer locale aléatoire.
- N’exposez pas directement le pont au réseau local ni à Internet. Le tunnel public temporaire est réservé aux tests contrôlés ; la clé reste obligatoire.
- Révoquez et remplacez toute clé qui a déjà été collée dans une conversation, une capture d’écran, une issue ou un journal.

## Télécharger un paquet source validé (alpha)

Un workflow manuel GitHub Actions crée un ZIP contenant uniquement les sources et valide l’archive extraite avant de la téléverser :

1. Ouvrez [Actions](https://github.com/omid-cyber/ai-prime-cursor-manager/actions/workflows/package-alpha-source.yml).
2. Choisissez **Package Alpha Source Bundle**, sélectionnez **Run workflow** sur \`main\` et attendez la fin de l’exécution.
3. Téléchargez l’artefact \`ai-prime-cursor-manager-source-<commit>\` depuis une exécution réussie. L’artefact expire au bout de 14 jours.
4. Extrayez complètement le ZIP dans un dossier normal et lancez \`Start-AI-Prime-Cursor-Manager.bat\`.

Le workflow relance les vérifications de syntaxe Node, les tests hors ligne Bridge/Tunnel et le contrôle préalable PowerShell/XAML. Il extrait aussi le ZIP dans un nouveau dossier et répète les contrôles sur cette copie.

**Il s’agit d’un paquet source validé, pas d’un EXE compilé ni d’une version stable.** L’interface WPF réelle et le véritable Cloudflare Quick Tunnel doivent encore être testés manuellement sous Windows 10/11. Aucune licence de redistribution n’a été choisie ; consultez \`LICENSE-DECISION.md\`.

## Maturité actuelle du projet

Le code inclut des corrections historiques après des erreurs d’exécution Windows ; les tests du code source ne remplacent donc pas un test complet de l’interface sur Windows. Consultez [TEST-REPORT.md](TEST-REPORT.md) et [docs/RELEASING.md](docs/RELEASING.md). Pour signaler un problème, supprimez les secrets et fournissez le texte exact de l’erreur.

## Licence

Le propriétaire du projet n’a pas encore choisi de licence. Tant qu’un fichier de licence n’est pas ajouté, tous les droits sont réservés : ne redistribuez pas le code et ne créez pas d’œuvres dérivées. Choisissez une licence avant de présenter le projet comme open source.