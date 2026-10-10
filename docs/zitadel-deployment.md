# Zitadel — déploiement préparé

## Périmètre

Instance pilote sur `https://zitadel.dohrm.fr`, séparée d'Authentik. Aucune
application Temper, source sociale ou migration de comptes n'est créée ici.

- Chart officiel **10.4.0**, API et Login V2 **v4.19.2**.
- Namespace `zitadel`, un pod API et un pod Login V2 sur `vps-4541d883`.
- Base et rôle `zitadel` dans le CNPG `postgres-prod` existant, PostgreSQL 18.4.
- Cache PostgreSQL uniquement ; Redis et PostgreSQL embarqué désactivés.
- `init zitadel` initialise les schémas avec le propriétaire de la base, sans
  identifiants superuser. CNPG crée préalablement le rôle et la base.
- Les CR CNPG conservent base et rôle en cas de suppression (`retain`).

Les secrets SOPS comprennent le mot de passe PostgreSQL, la masterkey de
32 caractères, le mot de passe bootstrap, le certificat RSA de Login V2 et la
clé de signature de ses cookies. Les deux copies du mot de passe PostgreSQL
doivent être mises à jour ensemble en cas de rotation. Ne pas régénérer la
masterkey lors d'un redéploiement : elle permet de déchiffrer les données.

Le certificat interne de Login V2 est fourni par SOPS plutôt que généré à
chaque rendu Helm. Il authentifie Login V2 auprès de l'API ; ce n'est pas le
certificat HTTPS public. Aucun compte machine administrateur ni PAT n'est créé
au bootstrap ; l'automatisation sera configurée à l'étape suivante.

## Réseau avant mise en service

L'Ingress expose `/ui/v2/login` vers `zitadel-login:3000` et les autres routes
vers `zitadel:8080`. Le Service API configure Traefik en **h2c**. Caddy termine
le TLS public et doit aussi parler HTTP/2 à Traefik pour la console gRPC.

Le Caddyfile hôte n'est pas versionné ici. Vérifier son transport avant la
mise en service ; la route HTTP classique d'Authentik ne suffit pas à prouver
le fonctionnement gRPC. Dans le bloc wildcard public existant, un handler
spécifique peut précéder le handler général :

```caddyfile
@zitadel host zitadel.dohrm.fr
handle @zitadel {
    reverse_proxy localhost:81 {
        transport http {
            versions h2c 1.1
        }
    }
}
```

Ce fragment s'intègre au bloc existant et à ses réglages TLS ; il ne constitue
pas un Caddyfile complet. Vérifier et recharger Caddy après adaptation.

External-dns surveille les Ingress `dohrm.fr` et publiera l'adresse du VPS
`51.178.19.49` (intervalle de 10 minutes). Le 2026-10-09, le nouveau nom ne
résolvait pas encore depuis la machine de préparation.

## Ordre de déploiement

1. Publier les modifications CNPG, puis attendre que le rôle et la base
   `zitadel` soient réconciliés. Les sync waves d'une Application ne séquencent
   pas les autres Applications : vérifier CNPG avant le premier install Helm.
2. Publier l'application `applications/zitadel/` sur `main`. L'ApplicationSet
   l'auto-découvre. Le Secret SOPS est créé en wave `-1`, puis le HelmChart.
3. Le chart exécute les hooks `zitadel-init`, puis `zitadel-setup`, puis démarre
   l'API et Login V2. Un premier échec dû à une base absente exige de relancer
   le HelmChart après réconciliation CNPG.
4. Vérifier DNS, TLS, transport h2c et accès à la console.

```bash
kubectl --kubeconfig=~/.kube/home.dohrm -n postgres-prod get databaserole zitadel
kubectl --kubeconfig=~/.kube/home.dohrm -n postgres-prod get database zitadel
kubectl --kubeconfig=~/.kube/home.dohrm -n zitadel get helmchart,jobs,deploy,pods,ingress
kubectl --kubeconfig=~/.kube/home.dohrm -n zitadel logs job/zitadel-init
kubectl --kubeconfig=~/.kube/home.dohrm -n zitadel logs job/zitadel-setup
curl -fsS https://zitadel.dohrm.fr/.well-known/openid-configuration
```

Console : `https://zitadel.dohrm.fr/ui/console`. Compte bootstrap :
`dohr.michael@gmail.com`. Le mot de passe est dans
`applications/zitadel/zitadel.secret.yaml`, sous
`stringData.config-yaml → FirstInstance.Org.Human.Password`, à consulter avec
SOPS dans ton terminal. Il doit être changé à la première connexion. L'adresse
du compte bootstrap est marquée vérifiée ; SMTP n'est pas encore configuré.

## Ressources et vérification

Demande permanente ajoutée : **200m CPU / 768 Mi** ; limites mémoire cumulées :
**1 536 Mi**. Chaque hook demande 100m / 256 Mi et est limité à 512 Mi.
Mesure du nœud le 2026-10-09 : 4 568 Mi demandés pour environ 7 751 Mi
allouables. Après ajout des deux pods : 5 336 Mi, soit environ 69 %.
Ces valeurs sont un budget initial, pas une mesure de consommation Zitadel.

Validations de préparation : intégrité de l'archive du chart, `helm lint`,
`helm template`, builds Kustomize sans KSOPS, déchiffrement et cohérence des
secrets. L'initialisation et le parcours de connexion restent à vérifier après
déploiement. Authentik et les paramètres OIDC de Temper restent inchangés.

## Administration par MCP

Pas de MCP d'administration officiel identifié dans la recherche du 2026-10-09.
Des projets communautaires existent, notamment
[takleb3rry/zitadel-mcp](https://github.com/takleb3rry/zitadel-mcp), qui annonce
la gestion des utilisateurs, projets et applications. Il n'a pas été audité ni
installé. Le support OAuth pour les clients MCP dans Zitadel est une autre
fonctionnalité : il ne fournit pas un serveur MCP d'administration.

## Références

- [Chart officiel, version 10.4.0](https://github.com/zitadel/zitadel-charts/releases/tag/zitadel-10.4.0)
- [Initialisation de la version 4.19.2](https://github.com/zitadel/zitadel/blob/v4.19.2/cmd/initialise/verify_zitadel.go)
- [Déploiement Kubernetes](https://zitadel.com/docs/self-hosting/deploy/kubernetes)
- [Prérequis et reverse proxy](https://zitadel.com/docs/self-hosting/manage/requirements)
