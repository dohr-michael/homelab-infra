# Préparation du cluster à une application critique

Statut : socle en place dans le repo, **prérequis nœuds et OVH à exécuter avant mise en service**.
Dernière révision : 2026-08-06.

Ce document couvre l'accueil d'une application déployée deux fois (DEV et PROD) avec
MongoDB en replica set, backups vers un blob storage OVH, RustFS comme S3 de dev,
monitoring et alerting.

---

## 1. État des lieux au 2026-08-06

Constats faits sur le cluster réel, pas sur le contenu du repo.

| Constat | Gravité | Statut |
|---|---|---|
| `argocd-repo-server` en crashloop depuis **28 jours** → les 7 Applications en sync `Unknown`, aucun déploiement depuis 28 jours | bloquant | **corrigé** (pod recréé) |
| etcd à **2 membres** : la majorité est de 2, donc perdre 1 VPS rend l'API server indisponible | bloquant | 3ᵉ VPS **commandé le 2026-08-06** (4 vCPU / 8 Go), attend la livraison |
| Snapshots etcd **locaux uniquement**, sur `vps-17435151` seul | bloquant | manifeste prêt, attend le bucket OVH |
| `vps-17435151` taint `CriticalAddonsOnly=true:NoSchedule` → rien ne s'y schedule, tout est sur `vps-a7c3e9b8` | élevée | **contourné** par toleration explicite dans les CR MongoDB |
| Aucun monitoring ni alerting (seul `metrics-server`) | élevée | **ajouté** (`applications/monitoring`) |
| `local-path` en `reclaimPolicy: Delete` : supprimer un PVC efface les données | élevée | **corrigé** (`local-path-retain`) |
| Métriques etcd non exposées (`127.0.0.1:2381` seulement) | moyenne | à activer sur les nœuds |
| ns `tinypaw` et `ai` présents dans le cluster, absents de git | faible | à réconcilier ou assumer |
| `gpu-worker-1060` NotReady depuis longtemps | faible | hors sujet ici |

### Cause racine du blocage ArgoCD, pour mémoire

L'init container `copyutil` fait `ln -s … /var/run/argocd/argocd-cmp-server`. Le volume
`var-files` est un `emptyDir`, qui **survit au redémarrage d'un container dans le même
pod**. Après le premier échec, chaque tentative retombait sur
`ln: File exists` → boucle infinie. Supprimer le pod suffit (nouvel `emptyDir`).
L'alerte `KubeContainerWaiting` et `ArgoCDSyncStatusUnknown` couvrent maintenant ce
mode de panne.

### Capacité réelle

| Nœud | vCPU | RAM | Disque libre | Rôle |
|---|---|---|---|---|
| `vps-a7c3e9b8` | 4 | 8 Go | 42 Go | control-plane + etcd, porte presque tout |
| `vps-17435151` | 4 | 8 Go | 64 Go | control-plane + etcd, **tainté** |
| `gmk-ai-master` | 32 | 48 Go | 950 Go | agent GPU, taint `dedicated=ai` |
| `gpu-worker-1060` | — | — | — | NotReady |

C'est cette asymétrie qui dicte toute la suite : **8 Go par VPS** interdit d'y faire
tenir deux environnements MongoDB, et `gmk-ai-master` est la seule vraie capacité.

---

## 2. Topologie cible

### Aujourd'hui (2 VPS + nœud maison)

```
                    ┌─ vps-a7c3e9b8 ──── mongo-prod-rs0-0   (votant)
MongoDB PROD  RS ───┼─ vps-17435151 ──── mongo-prod-rs0-1   (votant)
  3 votants         └─ gmk-ai-master ─── mongo-prod-rs0-2   (votant)
                                          → quorum 2/3, survit à la perte d'1 nœud

MongoDB DEV   RS 1 membre ─ gmk-ai-master
RustFS (S3 dev)           ─ gmk-ai-master
Monitoring (VM+Grafana)   ─ gmk-ai-master

Backups PROD  ─── PBM ──→ OVH Object Storage (logique + physique + PITR)
Backups DEV   ─── PBM ──→ RustFS in-cluster
Snapshots etcd ───────→ OVH Object Storage
```

Le 3ᵉ membre est un **membre porteur de données**, pas un arbitre. Un arbitre combiné
à `w: majority` est un anti-pattern MongoDB documenté : sur panne d'un porteur de
données, la durabilité de l'écriture n'est plus garantie. Un vrai membre donne à la
fois le vote et une 3ᵉ copie.

### Après l'arrivée du 3ᵉ VPS OVH

Les 3 membres de prod passent sur les 3 VPS OVH, en zones géographiques distinctes.
`gmk-ai-master` redevient dev + monitoring. etcd passe à 3 membres, donc tolère enfin la
perte d'un nœud.

Bénéfice secondaire non évident : les écritures en `w: majority` **accélèrent**. Tant
qu'un membre est à la maison, la majorité peut avoir à l'attendre sur un lien
résidentiel ; entre trois régions OVH on reste sur le backbone. Attendre plutôt 5-20 ms
de RTT inter-régions que les 11-30 ms observés vers la maison, et surtout une gigue bien
plus faible.

Option à considérer à ce moment-là, rendue intéressante par le fait qu'aucun VPS n'a de
RAM en réserve : garder `gmk-ai-master` comme **membre caché** du replica set. `votes: 0`,
`priority: 0`, invisible du routage des lectures clientes — donc sans effet sur les
élections ni sur la majorité, mais ça donne une 4ᵉ copie des données, chez soi, sur
950 Go de disque. Le bloc à ajouter dans `replsets[0]` :

```yaml
      hidden:
        enabled: true
        size: 1
        nodeSelector:
          role.homelab/mongodb-hidden: "true"
        tolerations:
          - key: dedicated
            operator: Equal
            value: ai
            effect: NoSchedule
        priorityClassName: homelab-platform
        # `storage` n'existe pas sous `hidden` : le cache se règle via `configuration`.
        configuration: |
          storage:
            wiredTiger:
              engineConfig:
                cacheSizeGB: 4
        resources:
          requests: { cpu: 250m, memory: 1Gi }
          limits: { cpu: "2", memory: 8Gi }
        volumeSpec:
          persistentVolumeClaim:
            storageClassName: local-path-retain
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: 50Gi
```

`hidden` plutôt que `nonvoting` : un membre `nonvoting` reste visible des clients, donc
un client en `readPreference: secondary` pourrait router ses lectures vers la maison à
travers Internet. `hidden` l'exclut du routage.

À arbitrer en connaissance de cause : ça ajoute un 4ᵉ mongod à maintenir et à surveiller,
pour une copie qui ne remplace pas un backup (elle réplique aussi les suppressions
accidentelles, en quelques millisecondes). Sa vraie valeur est de survivre à la perte
simultanée de plusieurs VPS OVH — pas à une erreur applicative.

### Choix structurants, et ce qu'ils coûtent

| Choix | Raison | Contrepartie assumée |
|---|---|---|
| Stockage `local-path` et non répliqué | MongoDB réplique déjà ; répliquer les blocs en dessous serait redondant et coûterait des I/O à travers le mesh Headscale | un PV est cloué à son nœud : nœud perdu = re-sync du membre depuis le RS, ou restore PBM |
| `allowVolumeExpansion: false` | le provisioner local-path ne sait pas étendre | dimensionner large dès le départ (20 Go/membre ici) |
| Dev sur le nœud maison | seul nœud avec RAM et disque | dev indisponible quand la maison est down |
| Monitoring sur le nœud maison | idem | **le monitoring meurt avec la maison** → canaux d'alerte hors cluster obligatoires, et un dead-man's switch reste à brancher (§7) |
| `tls.mode: preferTLS` | pas de cert-manager ; le trafic inter-nœuds est déjà dans le tunnel WireGuard de Headscale | un client peut se connecter en clair ; certificats auto-générés à renouveler à la main |
| `cacheSizeRatio: 0.4` sur 2 Gi de limite | le défaut MongoDB (50 % de RAM−1 Go ≈ 3,5 Go sur ces nœuds) ferait tomber le nœud entier | ~800 Mo de cache WiredTiger : suffisant pour un dataset modeste, à revoir si le working set grossit |
| Toleration de `CriticalAddonsOnly` plutôt que retrait du taint | garde `vps-17435151` fermé aux charges non critiques | il faut penser à la toleration pour toute future charge qui doit s'étaler |

---

## 3. Ce que ce commit ajoute

| Chemin | Contenu |
|---|---|
| `applications/cluster-baseline/` | StorageClass `local-path-retain`, 3 PriorityClasses, Secret de config etcd→S3 |
| `applications/mongodb-operator/` | Opérateur Percona PSMDB **1.23.0** cluster-wide, CRDs vendorisées |
| `applications/mongodb-prod/` | RS 3 membres, PBM → OVH S3, backup quotidien logique + hebdo physique + PITR |
| `applications/mongodb-dev/` | RS 1 membre sur le nœud maison, PBM → RustFS, backup toutes les 6 h |
| `applications/rustfs/` | RustFS 1.0.0-beta.12 + création automatique des buckets, console et API exposées |
| `applications/monitoring/` | vmsingle, vmagent, vmalert, Alertmanager, Grafana, node-exporter, kube-state-metrics, ~30 règles d'alerte |
| `infra/label-nodes.sh` | source de vérité des labels de placement `role.homelab/*` |
| `infra/validate-kustomize.sh` | `kustomize build` de toutes les apps sans KSOPS (le kubectl local ne fait pas d'exec plugin) |

Versions épinglées, toutes vérifiées le 2026-08-06 : PSMDB operator `1.23.0`,
Percona Server MongoDB `8.0.26-11`, PBM `2.15.0`, mongodb_exporter `0.52.0`,
VictoriaMetrics `v1.149.0`, Alertmanager `v0.33.1`, Grafana `13.1.2`,
kube-state-metrics `v2.19.1`, node-exporter `v1.12.1`, RustFS `1.0.0-beta.12`.

> MongoDB 8.0.26 est la dernière version proposée par Percona. Les versions 8.1/8.2
> amont ne sont pas packagées par PSMDB — « dernière version » veut donc dire ici
> « dernière 8.0 supportée par l'opérateur ».

### Détail non évident : `ServerSideApply` sur les CRDs

Le CRD `perconaservermongodbs.psmdb.percona.com` pèse **1,49 Mo**. Un apply côté client
stocke le manifeste dans l'annotation `kubectl.kubernetes.io/last-applied-configuration`,
plafonnée à 262 144 octets : le sync échouerait sur `metadata.annotations: Too long`.
D'où l'annotation `ServerSideApply=true,Prune=false` posée par patch kustomize sur les
4 CRDs. Ce n'est pas une optimisation, c'est une condition de fonctionnement.

---

## 4. Prérequis à exécuter — dans cet ordre

### 4.1 Commande OVH

**Nœud de calcul — ✅ commandé le 2026-08-06.** 4 vCPU / 8 Go, comme les deux autres,
dans une région distincte.

Conséquence à assumer : **aucun nœud du cluster n'a de RAM en réserve.** Les trois VPS
seront à 8 Go, le nœud maison reste le seul à avoir de la marge. Deux corollaires qui
courent dans tout ce document :

- le monitoring **restera durablement sur le nœud maison** — ce n'est plus une étape
  transitoire mais un état permanent, ce qui rend le dead-man's switch externe
  obligatoire et non plus optionnel (§7) ;
- le cache WiredTiger reste à ~800 Mo par membre (`cacheSizeRatio: 0.4` sur 2 Gi). Si le
  working set de l'application dépasse ça, les lectures partiront sur disque. C'est la
  première métrique à regarder en charge :
  `mongodb_ss_wt_cache_bytes_currently_in_the_cache` face à la taille du dataset.

**Object Storage.** Trois buckets, S3-compatible :

| Bucket | Classe | Région conseillée | Usage |
|---|---|---|---|
| `homelab-etcd-snapshots` | Standard | `eu-west-par` (3-AZ) | snapshots etcd |
| `homelab-mongodb-backups` | Standard + **versioning** | `eu-west-par` (3-AZ) | backups PBM de prod |
| `homelab-uploads` | High Performance | même région que les nœuds (`gra`/`sbg`/`rbx`) | uploads applicatifs |

`eu-west-par` est une région 3-AZ : c'est le meilleur choix pour des backups, dont on
veut avant tout la durabilité. High Performance n'y est pas disponible, mais un backup
n'a pas besoin de latence — un upload applicatif, si. D'où la séparation.

Créer **un utilisateur S3 par usage**, pas un seul pour les trois : les credentials de
backup ne doivent pas pouvoir toucher au bucket d'upload, et inversement.

Endpoint : `https://s3.<region>.io.cloud.ovh.net`.

Ajouter une lifecycle rule sur `homelab-mongodb-backups` (transition vers Infrequent
Access après 30 j, expiration après 180 j) — PBM gère sa propre rétention par nombre,
la lifecycle est le filet de sécurité contre les orphelins.

### 4.2 Labels de nœuds

Rien ne se schedule avant ça : tous les CR sélectionnent sur `role.homelab/*`.

```bash
KUBECONFIG=~/.kube/home.dohrm ./infra/label-nodes.sh
```

### 4.3 Renseigner les secrets

Quatre fichiers contiennent des placeholders. Les mots de passe MongoDB et Grafana sont
déjà générés aléatoirement, pas besoin d'y toucher.

```bash
# Credentials S3 OVH pour les backups MongoDB + nom du bucket
sops applications/mongodb-prod/mongo-backup-s3.secret.yaml

# Credentials S3 OVH pour les snapshots etcd + nom du bucket
sops applications/cluster-baseline/etcd-s3.secret.yaml

# Token du bot Telegram, chat_id, webhook Discord
sops applications/monitoring/alertmanager.secret.yaml
```

Puis le nom du bucket, en clair dans le CR (ce n'est pas un secret) :

```bash
# applications/mongodb-prod/10-psmdb.yaml → backup.storages.ovh-s3.s3.bucket
#   et .region / .endpointUrl si la région retenue n'est pas `gra`
```

Lire le mot de passe Grafana généré :

```bash
sops -d applications/monitoring/grafana.secret.yaml | grep admin-password
```

### 4.4 Configuration des nœuds k3s (accès SSH requis)

Ces changements ne sont pas versionnables dans git. Sur **chaque nœud control-plane**,
dans `/etc/rancher/k3s/config.yaml` :

```yaml
# Snapshots etcd vers OVH. Les credentials viennent du Secret SOPS déjà déployé,
# donc rien de sensible n'atterrit sur le disque du nœud.
etcd-s3: true
etcd-s3-config-secret: etcd-s3-config
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 10

# Expose les métriques etcd au-delà de 127.0.0.1, sinon les alertes etcd du
# groupe `etcd` restent muettes en permanence.
etcd-expose-metrics: true
```

puis `systemctl restart k3s`.

> **Séquencer maintenant, pas plus tard.** Avec 2 membres etcd, redémarrer un serveur
> casse temporairement le quorum. À faire **avant** que des données de production
> soient sur le cluster, un nœud à la fois, en vérifiant
> `kubectl get nodes` entre les deux.

> **Le Secret ne sert pas à la restauration.** Pendant un restore, l'apiserver est
> arrêté : k3s ne peut pas lire le Secret. Il faut passer
> `--etcd-s3-access-key` / `--etcd-s3-secret-key` en flags. **Garder ces credentials
> hors du cluster** (gestionnaire de mots de passe), sinon la sauvegarde est
> inatteignable exactement le jour où on en a besoin.

### 4.5 Ordre de déploiement

Les Applications sont découvertes automatiquement par l'ApplicationSet au push sur
`main`. L'ordre compte quand même, parce que les dépendances traversent les Applications
(ArgoCD ne sait pas ordonner entre Applications, il retente) :

1. `cluster-baseline` — la StorageClass et les PriorityClasses sont référencées par tout le reste
2. `mongodb-operator` — les CRDs doivent exister avant les CR
3. `rustfs` — la cible S3 de dev doit répondre avant le premier backup dev
4. `mongodb-dev` puis `mongodb-prod`
5. `monitoring`

En pratique : pousser `cluster-baseline` et `mongodb-operator` d'abord, attendre
`Healthy`, puis le reste. Sans ça les autres apps échouent en boucle quelques minutes
avant de converger — bruyant, pas cassant.

---

## 5. Validation

### 5.1 Le socle répond

```bash
export KUBECONFIG=~/.kube/home.dohrm
kubectl -n argocd get applications
kubectl get sc local-path-retain
kubectl -n mongodb-operator get deploy
kubectl -n mongodb-prod get psmdb,pods -o wide   # 3 pods, 3 nœuds différents
kubectl -n mongodb-dev  get psmdb,pods -o wide
```

Vérifier explicitement l'étalement, c'est tout l'objet de l'anti-affinité :

```bash
kubectl -n mongodb-prod get pods -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName
```

### 5.2 Les métriques MongoDB portent bien les noms attendus

Les alertes du groupe `mongodb-runtime` sont marquées « second rang » dans
`applications/monitoring/files/alert-rules.yml` : les noms de séries de
`percona/mongodb_exporter` varient selon les versions. **À faire une fois, au premier
déploiement** — une alerte qui ne peut pas se déclencher est pire que pas d'alerte :

```bash
POD=$(kubectl -n mongodb-dev get pod -l app.kubernetes.io/instance=mongo-dev \
        -o jsonpath='{.items[0].metadata.name}')
kubectl -n mongodb-dev exec "$POD" -c mongodb-exporter -- \
  wget -qO- localhost:9216/metrics | grep -E '^mongodb_(up|rs_)' | head -40
```

Vérifier en particulier l'**unité** de `mongodb_rs_members_optimeDate` (secondes ou
millisecondes) : le seuil de `MongoDBReplicationLagHigh` en dépend.

Les groupes `mongodb-state` et `mongodb-backup` reposent sur des métriques définies
dans `files/ksm-customresourcestate.yml`, donc dans ce repo : ceux-là sont fiables par
construction et constituent le vrai filet de sécurité.

### 5.3 La chaîne de backup fonctionne — et la restauration aussi

C'est le seul test qui compte. Un backup jamais restauré n'est pas un backup.

```bash
# Backup à la demande en dev
kubectl -n mongodb-dev create -f - <<'EOF'
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDBBackup
metadata:
  generateName: manual-
  namespace: mongodb-dev
spec:
  clusterName: mongo-dev
  storageName: rustfs
EOF

kubectl -n mongodb-dev get psmdb-backup -w      # attendre state: ready
```

Vérifier que les objets sont bien dans RustFS, puis écrire une donnée témoin, la
supprimer, et restaurer :

```bash
kubectl -n mongodb-dev create -f - <<'EOF'
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDBRestore
metadata:
  generateName: restore-
  namespace: mongodb-dev
spec:
  clusterName: mongo-dev
  backupName: <nom-du-backup>
EOF
```

Refaire l'exercice sur `mongodb-prod` vers OVH **avant** la mise en service, et noter
le temps de restauration réel : c'est le RTO, et il ne se devine pas.

### 5.4 L'alerting arrive vraiment

```bash
# Déclenche une alerte de test via l'API Alertmanager
kubectl -n monitoring port-forward svc/alertmanager 9093:9093 &
curl -XPOST localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[{
  "labels": {"alertname":"TestAlerting","severity":"critical"},
  "annotations": {"summary":"Test de la chaîne de notification"}
}]'
```

Un message doit arriver sur Telegram **et** Discord (le receiver `critical` route vers
les deux). Vérifier aussi les cibles réellement scrapées sur
`https://metrics.home.dohrm.fr/targets`.

---

## 6. Arrivée du 3ᵉ nœud OVH

1. Joindre le nœud comme **server** (control-plane + etcd) : procédure complète et
   scriptée dans **`docs/add-k3s-node.md`** + `infra/new-node-bootstrap.sh`. etcd passe
   à 3 membres, c'est là que le cluster devient réellement tolérant à une panne.
2. Vérifier : `kubectl get nodes` → 3 control-planes `Ready`.
3. Déplacer le membre MongoDB de prod hors du nœud maison, **un seul changement à la
   fois** :

```bash
# 1. Labelliser le nouveau nœud
kubectl label node <nouveau-noeud> role.homelab/mongodb-prod=true

# 2. Retirer le label du nœud maison
kubectl label node gmk-ai-master role.homelab/mongodb-prod-

# 3. Supprimer le pod concerné : l'opérateur le reconstruit sur le nouveau nœud
#    et le nouveau membre se resynchronise depuis le RS (initial sync).
kubectl -n mongodb-prod delete pod mongo-prod-rs0-2
```

4. Le PVC de l'ancien membre reste en `Released` sur le nœud maison
   (`reclaimPolicy: Retain`, c'est voulu). Le supprimer **seulement après** avoir
   confirmé que le RS est à 3 membres sains :

```bash
kubectl -n mongodb-prod get psmdb mongo-prod -o jsonpath='{.status.ready}/{.status.size}'
```

5. Mettre `PROD_NODES` à jour dans `infra/label-nodes.sh` et commiter — c'est la source
   de vérité, elle ne doit pas diverger du cluster.
6. Attendre que `EtcdQuorumFragile` se taise : elle est écrite pour ça.

---

## 7. Ce qui reste ouvert

Par ordre de valeur décroissante.

| Sujet | Pourquoi ça compte | Effort |
|---|---|---|
| **Dead-man's switch externe** | Le monitoring est sur le nœud maison. S'il tombe, plus aucune alerte n'est émise — et le silence est indistinguable de « tout va bien ». L'alerte `Watchdog` et le receiver `null` sont déjà en place : il reste à faire consommer ce flux par un service externe (Healthchecks.io, ntfy hébergé ailleurs, ou une Lambda). **C'est le trou le plus important qui reste, et le 3ᵉ VPS commandé à 8 Go ne le refermera pas** : il n'y aura pas de nœud OVH capable d'héberger le monitoring, donc ce n'est plus un contournement temporaire. | faible |
| **Tester la restauration etcd** | Les snapshots partiront chez OVH, mais un snapshot jamais restauré ne vaut rien. À faire une fois, sur un cluster jetable. | moyen |
| `NetworkPolicy` | k3s applique les NetworkPolicy nativement. Aujourd'hui tout pod peut joindre MongoDB. Un `default-deny` sur `mongodb-prod` + un allow explicite depuis le namespace de l'app réduit franchement la surface. | faible |
| **cert-manager + `requireTLS`** | Les certificats MongoDB sont auto-générés et à renouveler à la main (10 ans ici, donc pas urgent, mais c'est une dette datée). cert-manager permettrait aussi `requireTLS` et de vrais certificats sur les ingress. | moyen |
| **Dashboards Grafana** | Seule la datasource est provisionnée. Provisionner aussi les dashboards (MongoDB, node, kube) par ConfigMap, pour qu'ils survivent à la perte du PVC. | faible |
| ~~Rapatrier le monitoring hors de la maison~~ | **Écarté** : les 3 VPS seront à 8 Go, aucun n'a la place pour vmsingle + Grafana en plus d'un mongod. Reste comme alternatives, si le besoin devient réel : un agent léger poussant vers un SaaS (Grafana Cloud free tier, ~150 Mo dans le cluster), ou un 4ᵉ petit VPS dédié. | — |
| **Réconcilier le drift** | ns `tinypaw` et `ai` tournent hors GitOps. Soit les rapatrier dans `applications/`, soit les documenter comme volontairement manuels. | faible |
| **Audit IA périodique** | Voir `infra/ai-audit-prompt.md` : prompt prêt à être branché sur un agent planifié. | faible |

---

## 8. Points de vigilance à l'exécution

- **RustFS est en beta** (`1.0.0-beta.12`). Aucune donnée de production ne doit y aller.
  Le S3 de prod est OVH, point.
- **Les credentials RustFS sont dupliqués** dans `applications/rustfs/rustfs.secret.yaml`
  et `applications/mongodb-dev/mongo-backup-s3.secret.yaml` : un Secret ne traverse pas
  les namespaces. Les faire tourner = éditer les deux.
- **Le repo est public.** C'est pour ça que la config Alertmanager utilise
  `bot_token_file` / `chat_id_file` / `webhook_url_file` : le routage reste relisible en
  clair, aucun credential n'apparaît. Ne jamais mettre un token directement dans
  `files/alertmanager.yml`.
- **PITR nécessite un backup de base abouti** pour démarrer. Tant que le premier backup
  n'est pas passé, `PSMDBNoBackupEver` est légitimement en alerte.
- **`unsafeFlags.replsetSize: true`** n'existe que dans `mongodb-dev` pour autoriser un
  RS à 1 membre. Ne jamais le recopier dans `mongodb-prod`.
- **Écritures en `w: majority`** à travers le mesh Headscale : compter ~30-60 ms par
  écriture acquittée tant qu'un membre est chez soi. L'application doit être écrite en
  conséquence (pas d'écriture unitaire dans une boucle serrée).
