# Préparation du cluster à une application critique

Statut : cluster k3s à 3 nœuds **en place**, manifestes prêts dans le repo,
**commande OVH Object Storage et déploiement restant à faire**.
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
| etcd à **2 membres** : la majorité est de 2, donc perdre 1 VPS rend l'API server indisponible | bloquant | **résolu le 2026-08-06** — `vps-4541d883` (100.64.0.11) a rejoint, etcd est à 3 membres |
| Snapshots etcd **locaux uniquement**, sur `vps-17435151` seul | bloquant | manifeste prêt, attend le bucket OVH |
| `vps-17435151` taint `CriticalAddonsOnly=true:NoSchedule` → rien ne s'y schedule, tout est sur `vps-a7c3e9b8` | élevée | **contourné** par toleration explicite dans les CR MongoDB |
| Aucun monitoring ni alerting (seul `metrics-server`) | élevée | **ajouté** (`applications/monitoring`) |
| `local-path` en `reclaimPolicy: Delete` : supprimer un PVC efface les données | élevée | **corrigé** (`local-path-retain`) |
| Métriques etcd non exposées (`127.0.0.1:2381` seulement) | moyenne | **1 nœud sur 3** — activé sur `vps-4541d883`, reste à faire sur les deux anciens (§4.6) |
| ns `tinypaw` et `ai` présents dans le cluster, absents de git | faible | à réconcilier ou assumer |
| **Traefik joignable depuis Internet** : ServiceLB (hostPort + NodePort) contourne ufw, donc le filtre `100.64.0.0/16` de Caddy. n8n et ArgoCD étaient publics | **critique** | **corrigé le 2026-08-06** — `loadBalancerSourceRanges` + `allocateLoadBalancerNodePorts: false` (`cluster-baseline/30-traefik-lb.yaml`) |
| **`vps-17435151` sans pare-feu** : `ufw` installé mais `inactive`, API server (6443) et kubelet (10250) sur Internet en v4 et v6 | **critique** | **corrigé le 2026-08-06** — `infra/fixes/ufw-baseline.sh` |
| **MongoDB refuse tout kernel >= 6.19** (SERVER-121912, TCMalloc vs rseq) — sans borne haute, testé jusqu'à l'image 8.3.7-1 sur kernel 7.1.6 | **structurel** | **arbitré le 2026-08-06** (§8) : cluster de dev supprimé, dev vit sur le RS de prod isolé par base. Prod tient parce que les VPS sont en 6.8/6.11 |
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
| `vps-4541d883` | 4 | 8 Go | — | control-plane + etcd, rejoint le 2026-08-06, non tainté |
| `gmk-ai-master` | 32 | 48 Go | 950 Go | agent GPU, taint `dedicated=ai` |
| `gpu-worker-1060` | — | — | — | NotReady |

C'est cette asymétrie qui dicte toute la suite : **8 Go par VPS** interdit d'y faire
tenir deux environnements MongoDB, et `gmk-ai-master` est la seule vraie capacité.

---

## 2. Topologie

### Cible atteinte le 2026-08-06

Les trois VPS OVH sont en place et labellisés. Le plan transitoire qui plaçait un
membre de production sur le nœud maison n'a jamais eu à être appliqué : le 3ᵉ VPS est
arrivé avant le déploiement de MongoDB.

```
                    ┌─ vps-a7c3e9b8  100.64.0.1   mongo-prod-rs0-0   (votant)
MongoDB PROD  RS ───┼─ vps-17435151  100.64.0.3   mongo-prod-rs0-1   (votant)
  3 votants         └─ vps-4541d883  100.64.0.11  mongo-prod-rs0-2   (votant)
                       3 régions OVH → quorum 2/3, survit à la perte d'1 nœud

etcd          ── les 3 mêmes VPS (control-plane + etcd)
MongoDB DEV   ── supprimé : dev = base temper_dev sur le RS de prod (§8)
RustFS (S3 dev)                     ─ gmk-ai-master
Monitoring (VM+Grafana)             ─ gmk-ai-master

Backups PROD  ─── PBM ──→ OVH Object Storage (logique + physique + PITR)
(RustFS reste dispo comme S3 de test pour les uploads)
Snapshots etcd ───────→ OVH Object Storage
```

Les membres sont des **membres porteurs de données**, pas d'arbitre. Un arbitre combiné
à `w: majority` est un anti-pattern MongoDB documenté : sur panne d'un porteur de
données, la durabilité de l'écriture n'est plus garantie.

`gmk-ai-master` ne porte plus que dev, RustFS et le monitoring. L'option d'en faire un
**membre caché** du RS de production (4ᵉ copie chez soi, sans droit de vote) reste
ouverte — bloc YAML prêt ci-dessous.

### Conséquences de la bascule

Bénéfice secondaire non évident : les écritures en `w: majority` **accélèrent**. Tant
qu'un membre est à la maison, la majorité peut avoir à l'attendre sur un lien
résidentiel ; entre trois régions OVH on reste sur le backbone. Attendre plutôt 5-20 ms
de RTT inter-régions que les 11-30 ms observés vers la maison, et surtout une gigue bien
plus faible.

Option toujours ouverte, rendue intéressante par le fait qu'aucun VPS n'a de RAM en
réserve : garder `gmk-ai-master` comme **membre caché** du replica set. `votes: 0`,
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
| `cacheSizeRatio: 0.4` sur 2 Gi de limite | le défaut MongoDB (50 % de RAM−1 Go ≈ 3,5 Go sur ces nœuds) ferait tomber le nœud entier | **409 MiB** de cache WiredTiger — le ratio s'applique à `limite − 1 Gi`, pas à la limite (voir plus bas) : suffisant pour un dataset modeste, à revoir sous sonde |
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

**Nœud de calcul — ✅ livré et intégré le 2026-08-06** : `vps-4541d883`, 100.64.0.11,
4 vCPU / 8 Go, Ubuntu 24.04.4, k3s v1.34.3+k3s1. Procédure suivie :
`docs/add-k3s-node.md`.

Conséquence à assumer : **aucun nœud du cluster n'a de RAM en réserve.** Les trois VPS
seront à 8 Go, le nœud maison reste le seul à avoir de la marge. Deux corollaires qui
courent dans tout ce document :

- le monitoring **restera durablement sur le nœud maison** — ce n'est plus une étape
  transitoire mais un état permanent, ce qui rend le dead-man's switch externe
  obligatoire et non plus optionnel (§7) ;
- le cache WiredTiger est à **409 MiB par membre**, pas ~800 Mo comme annoncé
  initialement. La formule de l'opérateur est `(limite mémoire − 1 Gi) × cacheSizeRatio`,
  donc `(2 Gi − 1 Gi) × 0,4 = 409 MiB`. Mesuré le 2026-08-07, identique sur les trois
  membres :

  ```bash
  CU=$(kubectl -n mongodb-prod get secret mongo-prod-users -o jsonpath='{.data.MONGODB_CLUSTER_ADMIN_USER}' | base64 -d)
  P=$(kubectl -n mongodb-prod get secret mongo-prod-users -o jsonpath='{.data.MONGODB_CLUSTER_ADMIN_PASSWORD}' | base64 -d)
  kubectl -n mongodb-prod exec mongo-prod-rs0-0 -c mongod -- \
    mongosh "mongodb://$CU:$P@localhost:27017/admin" --quiet --eval \
    'print(db.serverStatus().wiredTiger.cache["maximum bytes configured"])'   # 428867584
  ```

  Le `− 1 Gi` correspond à ce que mongod consomme hors cache (connexions, tris,
  agrégations) : la répartition réelle des 2 Gi est ~409 MiB de cache et ~1,6 Gi de
  marge, ce qui est volontairement conservateur.

  **Décision du 2026-08-07 : on ne touche à rien pour l'instant.** La valeur sera
  ajustée sous sonde de performance une fois l'application déployée, pas à l'estime.
  Marge disponible le jour où c'est nécessaire : `0.7` donnerait ~716 MiB en laissant
  encore ~1,3 Gi. La métrique à regarder en charge est
  `mongodb_ss_wt_cache_bytes_currently_in_the_cache` face à la taille du dataset, et
  surtout le taux d'éviction — un cache saturé se voit d'abord aux lectures qui
  repartent sur disque.

**Object Storage — ✅ créé le 2026-08-08.** Les noms sont ceux générés par OVH, pas
des `homelab-*` : ne cherchez pas de bucket portant un nom parlant.

| Bucket | Région | Versioning | Usage |
|---|---|---|---|
| `eatable-wigner-mdohr` | `eu-west-par` (3-AZ) | non | snapshots etcd |
| `wrathful-millikan-mdohr` | `eu-west-par` (3-AZ) | **oui** | backups PBM de prod |
| `familiar-natarajan-mdohr` | `eu-west-par` | non | uploads applicatifs (aucun consommateur à ce jour) |

`eu-west-par` est une région 3-AZ : c'est le bon choix pour des sauvegardes, dont on
veut avant tout la durabilité. Un premier bucket de snapshots avait été créé en `rbx`
(mono-AZ) puis abandonné — la région d'un bucket ne se change pas, il faut en recréer un.

**Deux utilisateurs S3, pas trois** : un pour backup + snapshots, un pour upload. Le
cloisonnement qui compte est vérifié — l'utilisateur « upload » reçoit **403** sur le
bucket de backup. Contrepartie assumée : la copie hors cluster des credentials etcd
exigée par la restauration (§4.4) donne aussi accès aux backups MongoDB.

Endpoint : `https://s3.<region>.io.cloud.ovh.net`. **Attention, deux formats
coexistent** : PBM veut l'URL avec schéma et sans slash final, k3s
(`etcd-s3-endpoint`) veut le hostname nu. Ne pas recopier l'un sur l'autre.

**Lifecycle rule à créer sur `wrathful-millikan-mdohr` — pas encore faite.** Le
versioning rend `retention.deleteFromStorage: true` de PBM purement cosmétique :
mesuré le 2026-08-08, un PUT suivi d'un DELETE laisse 1 Version + 1 DeleteMarker, et
rien n'est libéré. La règle doit donc porter, en plus de la transition Infrequent
Access à 30 j et de l'expiration à 180 j :

- `NoncurrentVersionExpiration` — 30 jours
- `ExpiredObjectDeleteMarker: true`

Sans ces deux clauses, le bucket grossit indéfiniment malgré la rétention PBM.

**Répartition des rôles, arbitrée le 2026-08-08.** PBM garde `deleteFromStorage:
true` et reste la source de vérité sur ce qui est restaurable ; la lifecycle OVH
ne fait que récupérer l'espace des versions que PBM a déjà logiquement
supprimées. L'alternative documentée par Percona — `deleteFromStorage: false` et
tout déléguer aux politiques natives du cloud — a été écartée : elle laisse le
catalogue PBM lister des backups dont les fichiers ont disparu, donc un écart
entre ce qu'on croit restaurable et ce qui l'est.

Conséquence à accepter : un backup sorti de la rétention à J+14 n'est réellement
effacé du stockage que 30 jours plus tard.

**Roulement en place** — `retention.type` ne supporte que `count`, jamais une
durée ; une durée s'exprime donc en nombre de backups cohérent avec le cron. La
rétention s'applique **par tâche**, indépendamment, ce qui permet un schéma
grand-père/père/fils :

| Tâche | Cron | Rétention | Couvre |
|---|---|---|---|
| `daily-logical` | `0 2 * * *` | 14 | 2 semaines, granularité fine |
| `weekly-logical` | `0 3 * * 0` | 8 | 2 mois |
| `monthly-logical` | `0 4 1 * *` | 12 | 1 an |

⚠️ **La fenêtre PITR est bornée par le plus ancien backup de base survivant**,
pas par le nombre de backups : supprimer un backup de base efface les chunks
d'oplog qui s'appuient dessus. C'est donc `monthly-logical` qui donne la fenêtre
d'un an, et c'est elle qui détermine le volume d'oplog conservé.

La tâche `weekly-physical` a été supprimée : les backups physiques ne supportent
pas le PITR et servent à restaurer vite de gros volumes, alors qu'un restore
logique de 266 Mo prend quelques secondes. À reconsidérer à plusieurs dizaines
de Go, en même temps que le `cacheSizeRatio`.

Les horaires sont espacés volontairement : un backup bloqué retient le lease
`psmdb-mongo-prod-backup-lock` et l'opérateur refuse alors tout SmartUpdate.

**Avant toute rotation de credentials ou changement de bucket**, refaire la validation
HEAD/PUT/GET/DELETE : c'est ce qui garantit qu'on ne rejoue pas la panne du 2026-08-06
(bucket injoignable → PBM boucle → l'opérateur n'atteint jamais la création des comptes).

### 4.2 Labels de nœuds — ✅ fait le 2026-08-06

Rien ne se schedule sans ça : tous les CR sélectionnent sur `role.homelab/*`.

```bash
KUBECONFIG=~/.kube/home.dohrm ./infra/label-nodes.sh
```

État constaté : `mongodb-prod` sur les 3 VPS, `mongodb-dev` / `rustfs` / `monitoring`
sur `gmk-ai-master`. À rejouer après toute modification de `infra/label-nodes.sh`, qui
reste la source de vérité.

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

# DSN MongoDB + credentials S3 de l'application temper — ✅ renseignés le 2026-08-08
sops applications/temper-dev/10-infra-secrets.secret.yaml
sops applications/temper-prod/10-infra-secrets.secret.yaml
```

Le bucket d'upload `familiar-natarajan-mdohr` est **partagé entre dev et prod**,
avec un utilisateur S3 distinct par environnement (`UPLOAD_S3_*` et
`UPLOAD_DEV_S3_*` dans `.env`). Le cloisonnement est donc au niveau des
credentials, **pas du bucket** : prévoir un préfixe par environnement côté
application, sinon dev peut écraser des objets de prod.

Cloisonnement vérifié le 2026-08-08 — chacun des deux utilisateurs « upload »
reçoit **403** sur le bucket de backup.

⚠️ `MONGO_URI_SECRET` est une **copie** du DSN généré par l'opérateur
(`mongo-prod-temper*-user-conn-str`), amputée de `&tls=true` — voir §« piège
TLS ». Un Secret ne traversant pas les namespaces, une rotation du mot de passe
MongoDB doit être reportée à la main dans les deux fichiers ci-dessus.

Puis le nom du bucket, en clair dans le CR (ce n'est pas un secret) :

```bash
# applications/mongodb-prod/10-psmdb.yaml → backup.storages.ovh-s3.s3.bucket
#   et .region / .endpointUrl si la région retenue n'est pas `gra`
```

Lire le mot de passe Grafana généré :

```bash
sops -d applications/monitoring/grafana.secret.yaml | grep admin-password
```

### 4.4 Snapshots etcd vers OVH — le piège de la restauration

La configuration par nœud est détaillée en **§4.6** (elle diffère selon les nœuds : le
nouveau a déjà son `config.yaml`, les deux anciens portent tout en flags systemd).

Un point à retenir avant d'en dépendre :

> **Le Secret `etcd-s3-config` ne sert PAS à la restauration.** Pendant un restore
> l'apiserver est arrêté : k3s ne peut donc pas lire le Secret. Il faut passer
> `--etcd-s3-access-key` / `--etcd-s3-secret-key` en flags sur la ligne de commande.
> **Garder ces credentials hors du cluster** (gestionnaire de mots de passe), sinon la
> sauvegarde devient inatteignable exactement le jour où on en a besoin.

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

### 4.6 Exposer les métriques etcd sur les deux anciens nœuds

`vps-4541d883` a `etcd-expose-metrics: true` (posé par `new-node-bootstrap.sh`) et sert
bien ses 646 séries `etcd_*` sur `100.64.0.11:2381`. Les deux anciens nœuds, non : k3s
les garde sur `127.0.0.1:2381`. Vérifié le 2026-08-06 depuis `vps-a7c3e9b8` :

```
100.64.0.1     INJOIGNABLE
100.64.0.3     INJOIGNABLE
100.64.0.11    OK (646 séries etcd_*)
```

Conséquence concrète : deux membres etcd sur trois sont des angles morts — ils peuvent
perdre leur leader ou saturer leur disque sans qu'aucune alerte ne parte. C'est l'objet
de l'alerte `EtcdMembersNotScraped`.

**C'est maintenant que ça devient faisable.** Ces deux nœuds portent leur configuration
en flags dans l'unit systemd, sans `config.yaml`. On en crée un : k3s le lit en plus des
flags, et comme aucune de ces clés n'y figure, il n'y a pas de conflit.

Sur **chacun** des deux anciens nœuds, un à la fois :

```bash
sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<'EOF'
# Complète les flags de l'unit systemd — aucune clé en conflit avec eux.
etcd-expose-metrics: true

# Passer à true seulement quand le bucket OVH existe ET que le Secret
# etcd-s3-config est déployé (applications/cluster-baseline).
etcd-s3: false
etcd-s3-config-secret: etcd-s3-config
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 10
EOF
sudo chmod 600 /etc/rancher/k3s/config.yaml
sudo systemctl restart k3s
```

Puis **attendre que le nœud soit Ready avant de passer au suivant** :

```bash
kubectl get nodes -w
```

> Cette opération n'était pas sûre avant aujourd'hui : à 2 membres etcd, redémarrer un
> serveur cassait le quorum et rendait l'API server indisponible. À 3 membres, un
> redémarrage roulant est sans danger — **à condition de n'en redémarrer qu'un à la
> fois**. Perdre deux membres sur trois, c'est perdre la majorité.

Vérification, depuis n'importe quel nœud :

```bash
for ip in 100.64.0.1 100.64.0.3 100.64.0.11; do
  printf "%-14s " "$ip"
  curl -s -m4 "http://$ip:2381/metrics" | grep -c "^etcd_" || echo INJOIGNABLE
done
```

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

## 6. Intégration du 3ᵉ nœud OVH — ✅ fait le 2026-08-06

`vps-4541d883` (100.64.0.11) a rejoint comme server. etcd est à 3 membres, le cluster
tolère désormais la perte d'un nœud. Procédure et relevé de configuration :
`docs/add-k3s-node.md`.

**La migration de membre MongoDB décrite ici initialement n'a pas eu lieu, et c'est une
bonne nouvelle** : le nœud est arrivé avant le déploiement de MongoDB, donc il n'y a
jamais eu de membre de production sur le nœud maison à déplacer. Les labels pointent
directement sur la topologie cible.

Ce qui reste, côté nœuds : **§4.6**, exposer les métriques etcd sur les deux anciens
serveurs. C'est désormais sûr — ça ne l'était pas à 2 membres.

Si un membre doit être déplacé plus tard (remplacement de VPS, panne définitive), la
manœuvre est : labelliser la cible, retirer le label de la source, supprimer le pod
concerné — l'opérateur le reconstruit ailleurs et le membre se resynchronise depuis le
RS. Un seul changement à la fois, et le PVC de l'ancien membre reste en `Released`
(`reclaimPolicy: Retain`) : ne le supprimer qu'après avoir confirmé
`kubectl -n mongodb-prod get psmdb mongo-prod -o jsonpath='{.status.ready}/{.status.size}'`.

---

## 7. Ce qui reste ouvert

Par ordre de valeur décroissante.

| Sujet | Pourquoi ça compte | Effort |
|---|---|---|
| **Vérifier l'exposition réseau après chaque changement d'ingress** | L'audit du 2026-08-06 a montré que le « VPN-only » annoncé était faux : ServiceLB ouvrait Traefik sur Internet. L'alerte `UnexpectedPubliclyExposedService` couvre l'apparition d'un Service NodePort/LoadBalancer, mais pas un changement de règles ufw ni un hostPort direct. Un scan externe périodique (le prompt d'audit IA peut le porter) fermerait la boucle. | faible |
| **Dead-man's switch externe** | Le monitoring est sur le nœud maison. S'il tombe, plus aucune alerte n'est émise — et le silence est indistinguable de « tout va bien ». L'alerte `Watchdog` et le receiver `null` sont déjà en place : il reste à faire consommer ce flux par un service externe (Healthchecks.io, ntfy hébergé ailleurs, ou une Lambda). **C'est le trou le plus important qui reste, et le 3ᵉ VPS commandé à 8 Go ne le refermera pas** : il n'y aura pas de nœud OVH capable d'héberger le monitoring, donc ce n'est plus un contournement temporaire. | faible |
| **Tester la restauration etcd** | Les snapshots partiront chez OVH, mais un snapshot jamais restauré ne vaut rien. À faire une fois, sur un cluster jetable. | moyen |
| `NetworkPolicy` | k3s applique les NetworkPolicy nativement. Aujourd'hui tout pod peut joindre MongoDB. Un `default-deny` sur `mongodb-prod` + un allow explicite depuis le namespace de l'app réduit franchement la surface. | faible |
| **cert-manager + `requireTLS`** | Les certificats MongoDB sont auto-générés et à renouveler à la main (10 ans ici, donc pas urgent, mais c'est une dette datée). cert-manager permettrait aussi `requireTLS` et de vrais certificats sur les ingress. | moyen |
| **Dashboards Grafana** | Seule la datasource est provisionnée. Provisionner aussi les dashboards (MongoDB, node, kube) par ConfigMap, pour qu'ils survivent à la perte du PVC. | faible |
| ~~Rapatrier le monitoring hors de la maison~~ | **Écarté** : les 3 VPS seront à 8 Go, aucun n'a la place pour vmsingle + Grafana en plus d'un mongod. Reste comme alternatives, si le besoin devient réel : un agent léger poussant vers un SaaS (Grafana Cloud free tier, ~150 Mo dans le cluster), ou un 4ᵉ petit VPS dédié. | — |
| **Réconcilier le drift** | ns `tinypaw` et `ai` tournent hors GitOps. Soit les rapatrier dans `applications/`, soit les documenter comme volontairement manuels. | faible |
| **Audit IA périodique** | Voir `infra/ai-audit-prompt.md` : prompt prêt à être branché sur un agent planifié. | faible |

---

## 8. MongoDB : la contrainte kernel, et la suppression du cluster de dev

### Le fait, mesuré

Les images Percona MongoDB **refusent de démarrer sur tout kernel >= 6.19**. Le
TCMalloc embarqué viole l'ABI rseq de ces kernels ; mongod détecte la version et
s'arrête plutôt que de crasher (SERVER-121912). Symptôme : `CrashLoopBackOff`,
exit 1, **zéro ligne de log** — le message n'apparaît qu'en lançant le binaire à
la main.

**La borne haute annoncée n'existe pas dans les images actuelles.** La doc
MongoDB indique une sortie par le kernel >= 7.0.14 (SERVER-125742). Testé le
2026-08-06 sur kernel **7.1.6** :

| Image | Résultat |
|---|---|
| `percona-server-mongodb:8.0.26-11` | refuse |
| `percona-server-mongodb:8.3.7-1` (la plus récente) | **refuse aussi** |

Monter le kernel ne sert donc à rien aujourd'hui : le garde-fou est un simple
`>= 6.19` sans borne supérieure.

| Nœud | Kernel | MongoDB |
|---|---|---|
| `vps-a7c3e9b8` | 6.11.0 | OK |
| `vps-17435151` | 6.8.0 | OK |
| `vps-4541d883` | 6.8.0 | OK |
| `gmk-ai-master` | 7.1.6 | **refuse** |

### La décision : plus de cluster de dev

`applications/mongodb-dev/` a été supprimé. Aucune image ne peut tourner sur
`gmk-ai-master`, et c'était le seul nœud avec la capacité pour un second
cluster ; les VPS à 8 Go n'ont pas la place d'en héberger deux.

Dev vit donc sur le **replica set de production**, isolé par base de données :

| Utilisateur | Base | Droits | Secret |
|---|---|---|---|
| `temper` | `temper` | readWrite sur `temper` | `mongo-temper-user.secret.yaml` |
| `temper-dev` | `temper_dev` | readWrite sur `temper_dev` | `mongo-temper-dev-user.secret.yaml` |

La base de dev est `temper_dev` et non `temper-dev` : un tiret est légal dans un
nom de base MongoDB, mais casse `db.temper-dev` dans mongosh (lu comme une
soustraction) et impose `getSiblingDB("temper-dev")` partout. Le compte, lui,
garde le tiret.

Ce que ça garantit : `temper-dev` ne peut ni lire ni écrire dans `temper`. Un
mauvais DSN ne peut pas polluer l'autre environnement.

Ce que ça ne garantit pas, et qu'il faut assumer :

- **même cache WiredTiger** (409 MiB, voir §3) : une requête de dev qui parcourt
  une grosse collection évince le working set de prod
- même oplog, mêmes connexions, mêmes I/O disque
- les backups PBM couvrent tout le cluster, donc `temper_dev` part aussi chez OVH

### Ajouter un compte / une base

L'opérateur gère les utilisateurs de façon déclarative (`spec.users`), donc tout
passe par un commit — jamais par un `db.createUser()` à la main, qui serait
écrasé ou divergerait du dépôt :

1. créer `applications/mongodb-prod/mongo-<nom>-user.secret.yaml`
   (`stringData.password`), puis `sops --encrypt --in-place`
2. l'ajouter à `ksops-generator.yaml`
3. ajouter l'entrée dans `spec.users` du CR (`name`, `db`, `passwordSecretRef`,
   `roles`), commit

Il n'y a **rien à créer côté base de données** : une base MongoDB naît à la
première écriture et disparaît quand elle est vide. C'est pour ça que `temper` et
`temper_dev` n'apparaissent pas encore dans `listDatabases` alors que les comptes
existent.

La **rotation de mot de passe** suit la même voie : `sops` le secret, commit.
L'opérateur applique le nouveau mot de passe sans recréer l'utilisateur ni
toucher aux droits.

#### La suppression, elle, n'est PAS déclarative — et c'est un piège

**Retirer une entrée de `spec.users` ne supprime pas le compte du cluster.**
Vérifié sur l'opérateur 1.23.0 le 2026-08-07 lors du renommage `app` →
`temper` : les deux nouveaux comptes ont été créés (`INFO Creating user` dans les
logs), les deux anciens sont restés en base, avec leurs droits et leur ancien mot
de passe. L'opérateur ne garde aucune trace des comptes personnalisés qu'il a
créés — ni dans `.status`, ni dans `internal-mongo-prod-users` — il n'a donc
aucun moyen de savoir qu'une entrée a disparu du CR.

Conséquence de sécurité à ne pas sous-estimer : un compte « retiré » du dépôt
continue de fonctionner indéfiniment. Un credential qu'on croit révoqué ne l'est
pas.

La suppression doit donc être faite à la main, en plus du commit :

```bash
export KUBECONFIG=~/.kube/home.dohrm
U=$(kubectl -n mongodb-prod get secret mongo-prod-users -o jsonpath='{.data.MONGODB_USER_ADMIN_USER}' | base64 -d)
P=$(kubectl -n mongodb-prod get secret mongo-prod-users -o jsonpath='{.data.MONGODB_USER_ADMIN_PASSWORD}' | base64 -d)
kubectl -n mongodb-prod exec mongo-prod-rs0-0 -c mongod -- \
  mongosh "mongodb://$U:$P@localhost:27017/admin?replicaSet=rs0" --quiet --eval '
    db.getSiblingDB("<base>").dropUser("<compte>")'
```

Et pour auditer l'écart entre le dépôt et le cluster (à faire après toute
suppression) :

```bash
... --eval 'db.getSiblingDB("admin").system.users.find({db:{$nin:["admin"]}},
             {user:1,db:1}).toArray().forEach(u => print(u.db+" : "+u.user))'
```

Tout ce qui sort de là et n'est pas dans `spec.users` est un compte orphelin.

Limite à connaître par ailleurs : les rôles utilisables sont ceux de MongoDB
(`readWrite`, `read`, `dbAdmin`…). Pour un droit plus fin, il faut passer par
`spec.roles` (privilèges par collection/action), également déclaratif.

### Se connecter : le DSN fourni par l'opérateur, et son piège TLS

Pour chaque entrée de `spec.users`, l'opérateur génère un Secret
`<secret>-conn-str` contenant un DSN **complet, mot de passe inclus**. C'est ce
qu'il faut monter dans l'application plutôt que de recomposer le DSN à la main :

```bash
kubectl -n mongodb-prod get secret mongo-prod-temper-user-conn-str \
  -o jsonpath='{.data.temper_rs0_connectionString}' | base64 -d
```

Deux clés par secret : `..._connectionString` (les 3 membres énumérés) et
`..._connectionStringSrv` (`mongodb+srv://`, qui résout les membres par SRV).

**Le DSN généré porte `&tls=true`, et tel quel il ne fonctionne pas.** Vérifié le
2026-08-07 : la connexion tombe en `MongoNetworkError: self-signed certificate in
certificate chain`, puis, CA fournie, en `connection closed`. La raison est dans
la ligne de commande de mongod :

```
--tlsMode preferTLS --tlsCAFile /etc/mongodb-ssl/ca.crt
```

Une `tlsCAFile` sans `--tlsAllowConnectionsWithoutCertificates` signifie que
**toute connexion TLS doit présenter un certificat client** signé par cette CA.
Autrement dit, `tls=true` ici veut dire TLS *mutuel*, pas TLS simple. Confirmé
par l'essai réussi avec `tlsCAFile` **et** `tlsCertificateKeyFile`.

Deux options pour l'application, à choisir sciemment :

1. **Retirer `&tls=true` du DSN** (ce qui a été validé pour `temper` et
   `temper-dev`). `preferTLS` accepte les connexions en clair. Le trafic
   inter-nœuds passe déjà dans le tunnel WireGuard de Headscale, donc rien ne
   circule en clair sur Internet — mais le trafic pod → mongod dans un même nœud,
   lui, l'est.
2. **Monter le Secret `mongo-prod-ssl`** (`ca.crt`, `tls.crt`, `tls.key`) dans le
   pod applicatif et garder `tls=true`, en ajoutant `tlsCAFile` et
   `tlsCertificateKeyFile` (un seul fichier concaténant clé + certificat).

L'option 1 est celle en place aujourd'hui. Le passage à `requireTLS` (voir §7)
rendra l'option 2 obligatoire : c'est le vrai coût de ce changement, et c'est la
distribution du matériel cryptographique aux clients, pas le flag lui-même.

Dev peut donc **dégrader** prod — pas la corrompre, mais la ralentir. À garder en
tête si une charge de dev devient lourde ; le jour où ça gêne, la sortie est un
4ᵉ nœud sous 6.19, pas un retour sur gmk.

### Le risque qui reste, et il est sérieux

Les trois VPS tournent en 6.8 / 6.11. **C'est la seule raison pour laquelle
MongoDB fonctionne.** Un `apt upgrade` ou une montée de version d'Ubuntu qui
franchit 6.19 rend MongoDB indémarrable sur les trois nœuds en même temps — et
le pod ne le manifestera qu'au prochain redémarrage, donc potentiellement bien
après la mise à jour.

Point d'attention concret : **`vps-a7c3e9b8` est en Ubuntu 24.10, déjà en fin de
support.** Le mettre à niveau amènerait un kernel >= 6.19. Il faut donc soit
rester sur ce kernel malgré la fin de support, soit attendre une image Percona
qui lève le garde-fou — et la tester avant de toucher au nœud.

L'alerte `NodeKernelIncompatibleWithMongoDB` couvre **tout kernel >= 6.19**, sans
borne haute. Une première version ne visait que 6.19 → 7.0.13 et aurait laissé
passer un nœud monté en 7.1 : la regex est désormais testée contre les 5 kernels
réels du cluster plus les bornes 6.19 / 7.0.14 / 7.1.6 / majeures à deux chiffres.

---

## 9. Points de vigilance à l'exécution

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
