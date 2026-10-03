# authentik dans le cluster — faisabilité et migration Auth0

État au 2026-10-03. Cette PR prépare le déploiement GitOps ; aucun changement n'a été appliqué au cluster pendant l'étude.

## Décision technique

**Faisable**, sous réserve de valider la disponibilité d'un fournisseur d'identité public et de migrer les applications une par une. Le chart officiel authentik `2026.8.2` est épinglé. Depuis `2025.10`, authentik utilise PostgreSQL sans Redis. La base est créée dans le CNPG existant, dont le backup quotidien du 2026-10-03 est `completed` et l'archivage continu est `True`.

Le service utilise `auth.dohrm.fr`, accessible publiquement via le bloc Caddy `*.dohrm.fr` déjà employé pour `search.dohrm.fr`. Un nom `*.home.dohrm.fr` filtré par VPN bloquerait les utilisateurs d'applications publiques. L'Ingress est donc public ; les politiques d'accès se gèrent dans authentik. Avant la bascule, vérifier de l'extérieur TLS, redirections, WebSocket et en-têtes `X-Forwarded-*`. Le réglage `AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS=10.42.0.0/16` n'accorde confiance qu'au réseau des pods, d'où arrive Traefik ; vérifier l'adresse réelle dans les logs après installation. L'Ingress n'a pas de NodePort.

Deux pods, `server` et `worker`, sont épinglés sur `vps-4541d883`. Leur volume `/data` partagé est `ReadWriteOnce` sur `local-path-retain` (5 Gio). Cela assure les fichiers, mais **pas la haute disponibilité** : Caddy, PostgreSQL et le PVC sont déjà chacun des points uniques de défaillance. La PR ne modifie pas cette architecture. Les secrets sont chiffrés avec SOPS/age ; le mot de passe CNPG est dupliqué entre deux namespaces, comme pour n8n.

### Operator et AppConfig

Je n'ai pas trouvé d'opérateur officiel authentik avec CRD `AppConfig`. [La demande d'opérateur officiel est toujours une issue ouverte](https://github.com/goauthentik/authentik/issues/5675). L'opérateur communautaire [`dsluijk/authentik-operator`](https://github.com/dsluijk/authentik-operator) est **archivé depuis le 28 février 2026** et son bootstrap supprime `akadmin` ; il demande également Redis, incompatible avec l'architecture actuelle. Son installation n'est pas retenue pour une brique d'identité.

Le [chart officiel expose les blueprints via ConfigMaps](https://github.com/goauthentik/helm/blob/authentik-2026.8.2/charts/authentik/values.yaml) : `applications/authentik/10-blueprints.yaml` déclare le groupe de base et **Temper dev** avec son provider OIDC public. Ajouter les prochaines Applications et providers dans ce ConfigMap ou d'autres ConfigMaps référencés par `blueprints.configMaps`. ArgoCD versionne et réconcilie ces objets Kubernetes ; le worker authentik applique leurs blueprints. Ce mécanisme satisfait la gestion GitOps des configurations, sans CRD `AppConfig` ni opérateur additionnel. Les secrets des clients confidentiels doivent rester dans des Secrets SOPS ou être créés via l'API authentik, jamais dans un ConfigMap clair. Le client Temper dev est public avec PKCE et n'a pas de secret client.

## Ressources

Mesures `kubectl top nodes`, `kubectl top pods -A --containers`, `kubectl describe nodes` du 2026-10-03. Les valeurs `top` sont un instantané, pas un pic ni une garantie de consommation future.

| Nœud | Mémoire utilisée (`top`) | Mémoire demandée / allouable | CPU utilisé (`top`) | CPU demandé / allouable |
|---|---:|---:|---:|---:|
| `vps-a7c3e9b8` (Caddy) | 5 369 Mi / ~7 750 Mi (69 %) | 3 180 / ~7 750 Mi (41 %) | 487m / 4 cœurs | 1 140m / 4 cœurs |
| `vps-17435151` (taint) | 2 563 Mi / ~7 750 Mi (33 %) | 1 232 / ~7 750 Mi (15 %) | 266m / 4 cœurs | 390m / 4 cœurs |
| `vps-4541d883` (cible) | 3 266 Mi / ~7 750 Mi (42 %) | 3 128 / ~7 750 Mi (40 %) | 289m / 4 cœurs | 1 160m / 4 cœurs |
| `gmk-ai-master` (GPU) | 28 046 Mi / ~95 170 Mi (29 %) | 81 696 / ~95 170 Mi (85 %) | 2 099m / 32 cœurs | 20 560m / 32 cœurs |

La PR ajoute **200m CPU et 1 536 Mi de mémoire demandée** (`server` 100m/768 Mi, `worker` 100m/768 Mi), avec **3 072 Mi de limite mémoire cumulée**. Sur `vps-4541d883`, les demandes passeraient à **1 360m CPU (34 %) et 4 664 Mi (60 %)** ; marge de scheduling mémoire ~3 087 Mi. La consommation réelle attendue est à mesurer après démarrage : aucune mesure authentik n'existe encore dans ce cluster. À titre de comparaison, `n8n` consommait 329 Mi, `litellm` 885 Mi, le Postgres 182 Mi au même instant. Un dépassement de 1 536 Mi par pod provoquerait un OOM ; surveiller `kubectl top` et les redémarrages pendant la validation.

Le PVC ajoute **5 Gio réservés** sur le VPS cible. La base partage le PVC CNPG existant de 20 Gio, ses sauvegardes S3 et son WAL ; mesurer la croissance après la migration. Le volume `/data` n'est **pas** couvert par le backup CNPG : prévoir une sauvegarde distincte ou passer au stockage S3 avant de dépendre d'icônes et fichiers chargés.

## Sources sociales

| Source | Faisabilité | À préparer |
|---|---|---|
| Google | Oui, source OAuth native | ID client + secret OAuth **Web application**, redirect `https://auth.dohrm.fr/source/oauth/callback/google/` ; écran de consentement et domaine autorisé. |
| Apple (« appel » interprété comme Apple) | Oui, source native | Compte Apple Developer, App ID, Services ID, clé Sign in with Apple, Team ID et Key ID ; redirect `https://auth.dohrm.fr/source/oauth/callback/apple/`. Domaine public requis. |
| Facebook | Oui, source native | App Meta, Facebook Login, permission `email`, App ID + secret ; redirect `https://auth.dohrm.fr/source/oauth/callback/facebook/`. Publier l'app pour les utilisateurs hors rôles de test. |
| Instagram | Pas de source sociale native identifiée | Facebook Login **ne donne pas** une connexion Instagram équivalente. L'API Instagram Login vise les cas d'usage Instagram et demande une étude séparée des scopes/comptes Meta ; ne pas promettre ce bouton au cutover. |
| Discord | Oui, source native | Application Discord, Client ID + secret ; redirect `https://auth.dohrm.fr/source/oauth/callback/discord/`. |

Pour chaque source : `Directory > Federation and Social login > New Source`, choisir le type, fixer le slug indiqué ci-dessus, coller ID/secret dans *Consumer key/secret*, puis sélectionner la source dans le flux de connexion. Les sources ne deviennent pas automatiquement visibles sur la page de login.

### Procédure Google à faire de ton côté

Il s'agit d'un **OAuth Client ID et Client Secret**, pas d'un « API token » générique.

1. Ouvre [Google Cloud Console](https://console.cloud.google.com/), crée/sélectionne un projet.
2. Dans **Google Auth Platform / OAuth consent screen**, choisis *External* pour des comptes Google publics ; renseigne nom de l'application, email de support, domaine autorisé `dohrm.fr` et email de contact. Ajoute des testeurs tant que l'application reste en mode test.
3. Dans **Clients / Credentials**, crée un **OAuth client ID**, type **Web application**. Mets exactement `https://auth.dohrm.fr/source/oauth/callback/google/` dans les URI de redirection autorisés (slash final compris).
4. Récupère **Client ID** et **Client Secret** ; conserve le secret hors du chat/Git en clair. Dans authentik, crée `Google OAuth Source` avec slug `google`, renseigne ces deux champs, puis ajoute la source au flux de connexion.
5. Teste avec un compte Google autorisé et vérifie le rattachement au bon utilisateur avant d'ouvrir à tous.

## Pilote Temper dev

Le portail réellement déployé vient de `temper-altern` (`apps/web/src/core/auth/oidc.ts`). Il revient à `${window.location.origin}/callback` après connexion et à `${window.location.origin}` après déconnexion. Le blueprint autorise donc **strictement** `https://temper-dev.dohrm.fr/callback` et `http://localhost:5173/callback` pour la connexion ; `https://temper-dev.dohrm.fr` et `http://localhost:5173` pour la déconnexion. Il crée l'application `temper-dev`, un client public `temper-dev`, le flux Authorization Code avec PKCE et une signature RSA. Les rôles restent dans Temper ; aucune revendication de rôle n'est requise d'authentik.

Le dépôt `temper-deploy` doit ensuite remplacer ses quatre valeurs Auth0 sur la branche `dev` :

| Variable | Valeur authentik |
|---|---|
| `TEMPER_OIDC_ISSUER` | `https://auth.dohrm.fr/application/o/temper-dev/` |
| `TEMPER_OIDC_AUTHORITY` | `https://auth.dohrm.fr/application/o/temper-dev/` |
| `TEMPER_OIDC_AUDIENCE` | `temper-dev` |
| `TEMPER_OIDC_CLIENT_ID` | `temper-dev` |

Le [mode d'issuer par provider](https://docs.goauthentik.io/add-secure-apps/providers/oauth2/) produit `iss=https://auth.dohrm.fr/application/o/temper-dev/` ; l'access token émis pour ce client porte `aud=temper-dev`. L'API Temper vérifie ces deux valeurs et charge la clé depuis le JWKS. Tester les claims réels avec un utilisateur test avant de retirer Auth0. Pour le développement local de `temper-altern`, configurer son `config.js` avec le même issuer/client ID/audience ; le callback local est déjà autorisé par le blueprint. Le navigateur envoie encore un paramètre Auth0 `audience` à l'autorisation ; il vaut également `temper-dev`. Vérifier qu'authentik l'ignore ou le retirer dans `temper-altern` si la requête est refusée.

Les utilisateurs existants de Temper ne sont que des comptes de test. On peut les recréer dans authentik et réinitialiser les données de test liées au `sub` Auth0 ; aucune migration d'utilisateurs réels n'est nécessaire. Ne pas changer la configuration de `temper-prod` dans cette étape.

## Migration Auth0

1. Après le pilote Temper dev, inventorier **les autres applications** : callback, logout, audience, scopes, claims, règles/actions Auth0, connexions sociales et nombre d'utilisateurs. Leurs valeurs ne sont pas encore connues.
2. Exporter les utilisateurs et surtout la correspondance `Auth0 sub` ↔ identifiant applicatif. Le `sub` authentik sera différent : prévoir une table de correspondance ou rattacher les comptes par un identifiant vérifié. Ne pas dédupliquer aveuglément par email, qui n'est pas unique par défaut dans authentik.
3. Créer dans authentik une Application + un provider OIDC par application, avec redirect URI exacte et clé de signature. Tester issuer, JWKS, claims, refresh tokens, logout et rôles en parallèle d'Auth0.
4. Basculer une application pilote, conserver temporairement Auth0 comme retour arrière, puis migrer le reste. Les sessions et tokens Auth0 existants ne se transfèrent pas ; prévoir une reconnexion.
5. Configurer un SMTP de récupération et une procédure de restauration PostgreSQL + `/data` avant de retirer Auth0. L'absence de SMTP n'empêche pas le pilote mais empêche les emails de récupération.

## Vérification après fusion (pas encore exécutée)

```bash
KUBECONFIG=~/.kube/home.dohrm kubectl -n postgres-prod get databaseroles,databases
KUBECONFIG=~/.kube/home.dohrm kubectl -n authentik get helmchart,deploy,pod,pvc,ingress
KUBECONFIG=~/.kube/home.dohrm kubectl -n authentik top pods
curl -I https://auth.dohrm.fr/if/flow/initial-setup/
```

Se connecter ensuite avec `akadmin` et le mot de passe bootstrap du Secret chiffré `applications/authentik/authentik.secret.yaml` ; le changer après validation.

### Références

- [Installation Kubernetes et PostgreSQL externe](https://docs.goauthentik.io/install-config/install/kubernetes/)
- [Chart officiel `2026.8.2`](https://github.com/goauthentik/helm/releases/tag/authentik-2026.8.2)
- [Blueprints GitOps](https://docs.goauthentik.io/customize/blueprints/v1/structure/)
- [Google](https://docs.goauthentik.io/users-sources/sources/social-logins/google/cloud/), [Apple](https://docs.goauthentik.io/users-sources/sources/social-logins/apple/), [Facebook](https://docs.goauthentik.io/users-sources/sources/social-logins/facebook/), [Discord](https://docs.goauthentik.io/users-sources/sources/social-logins/discord/)
- [Reverse proxy et proxys de confiance](https://docs.goauthentik.io/install-config/reverse-proxy/)
- [Stockage de fichiers](https://docs.goauthentik.io/customize/files/)
