# Stack AI — AMD Strix Halo (ROCm)

LLM, embeddings et transcription sur le nœud `gmk-ai-master` (gfx1151), déployés par ArgoCD.
Backend **ROCm**, pas Vulkan : image `docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-7.14`.

## Ce qui tourne

| Service (ClusterIP `:8080`) | Modèle | Rôle |
|---|---|---|
| `qwen35b-a3b-llm-server` | Qwen3.6-35B-A3B UD-Q6_K + `mmproj-F16` | chat multimodal |
| `qwen3-embedding-4b-llm-server` | Qwen3-Embedding-4B Q8_0 | embeddings, 2560 dims |
| `whisper-server` | `ggml-large-v3-turbo` | transcription |

Aucun de ces services n'est exposé hors cluster. L'entrée publique est **LiteLLM**
(`applications/litellm/`), qui les agrège derrière `https://llm-api.home.dohrm.fr`.

Non déployés, conservés commentés dans `kustomization.yaml` : `20-sd-server.yaml`
(la génération d'images est passée sur ComfyUI **hôte**), `30-open-webui.yaml`,
`40-ingress.yaml`, et l'overlay de repli `overlays/qwen3.5-9b-decision`.

⚠ `overlays/gemma4` est **mort** : il alimente un `configMapGenerator llm-server-config`
que `base/llm.yaml` ne consomme plus, depuis le passage aux `env` directs.

## Structure

```
base/llm.yaml              # template Deployment + Service (llama-server ROCm)
overlays/<modèle>/         # un overlay par modèle : patche env + args
01-storage.yaml            # PV/PVC locaux, nodeAffinity sur gmk-ai-master
10-whisper-server.yaml     # whisper.cpp (image maison, hors du template llm)
```

Le template ne lit **que** des variables d'environnement (`MODEL_PATH`, `CTX_SIZE`,
`PARALLEL_SLOTS`, `THREADS`, `CACHE_TYPE_K/V`, `MODEL_ALIAS`). Un overlay les remplace
en bloc via un patch JSON `replace` sur `containers/0/env` et `initContainers/0/env`,
et ajoute ses flags par `add` sur `containers/0/args/-`.

## Ajouter un modèle

1. Télécharger le GGUF **sur le nœud**, dans `/home/michael/models/<repo>/` —
   c'est le chemin monté par le PV `ai-models-llm-pv`.
2. Créer `overlays/<nom>/kustomization.yaml` : `resources: [../../base]`, un
   `namePrefix`, des `labels` avec `includeSelectors: true`, et le patch d'`env`.
3. Décommenter l'overlay sous `resources:` dans `kustomization.yaml`.
4. Ajouter la route dans `applications/litellm/20-config.yaml`.

L'`initContainer` `check-model` échoue volontairement si le fichier est absent :
un modèle non téléchargé donne un pod en `Init:Error`, pas un serveur silencieusement
vide.

## Budget mémoire — mesuré, pas estimé

Le nœud n'a **pas** les « ~172 Go » qu'annonçait l'ancienne documentation : ce chiffre
additionnait VRAM et GTT, alors que les deux sont pris sur la même RAM physique.

| Mesure (2026-09-26) | Valeur |
|---|---|
| `MemTotal` | **92,9 Gio** |
| `MemAvailable`, 3 modèles résidents | **17,2 Gio** |
| GTT utilisé / total | 50,4 / 90,2 Gio |
| VRAM dédiée | 1 Gio |
| `requests` K8s / allouable | 67 / 92,9 Gio |

Poids résidents : 27,3 Gio (35B-A3B Q6_K) + 0,86 (mmproj) + 4,0 (embedding) + whisper.

**La RAM est une contrainte dure.** Une seconde instance 35B-A3B ne rentre pas, et le
scheduler la refuse avant même l'OOM. Chiffrer avant d'ajouter un modèle :

```bash
KUBECONFIG=~/.kube/home.dohrm kubectl exec -n ai-stack deploy/qwen35b-a3b-llm-server -- \
  sh -c 'grep -E "MemTotal|MemAvailable" /proc/meminfo
         cat /sys/class/drm/card*/device/mem_info_gtt_used'
```

Coût du KV cache, à calculer depuis les métadonnées du GGUF
(`block_count × head_count_kv × (key_length + value_length) × 2 octets` par token
en f16) :

| Modèle | KV / token (f16) | à 16k | à 64k |
|---|---|---|---|
| Qwen3.6-35B-A3B | 80 KiB | 1,25 Gio | 5,0 Gio |
| Qwen3.5-9B | 128 KiB | 2,0 Gio | 8,0 Gio |
| Qwen3-Embedding-4B | 144 KiB | 2,25 Gio | — |

Le contexte se **divise** entre slots : `n_ctx_slot = CTX_SIZE / PARALLEL_SLOTS`.

## Prérequis sur le nœud

```bash
uname -r                  # ≥ 6.18.4 — bug gfx1151 en deçà
rpm -q linux-firmware     # ≥ 20260110. NE PAS utiliser 20251125 (casse ROCm)
ls /dev/dri /dev/kfd      # accès GPU
```

Labels et taint (voir aussi `infra/label-nodes.sh`) :

```bash
kubectl label node gmk-ai-master gpu-type=strix-halo
kubectl taint node gmk-ai-master dedicated=ai:NoSchedule
```

Paramètres GRUB pour la mémoire GPU — procédure complète dans
`infra/strix-halo-gpu-memory.md` :

```
amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856
```

## Flags llama-server vérifiés (build b10664)

Contraintes matérielles :

- `--no-mmap` — **obligatoire**, évite les crashs mmap sur gfx1151
- `-fa 1` (flash attention), `-ngl 999` (tous les layers sur GPU)
- `securityContext: privileged: true, runAsUser: 0` — SELinux bloque les allocations HSA sinon
- `strategy: Recreate` — le GPU est partagé, pas de rolling update

Pour tout usage « probabilités » (classification, routage, décision) :

- les `logprobs` sont renvoyés **avant sampling**. Mesuré : valeurs identiques à
  `temperature` 0 et 2.0, insensibles à `top_k`. En revanche une requête qui passe
  `post_sampling_probs: true` les écrase à `1.0` — à ne jamais activer.
- `--reasoning-budget 0` est **obligatoire** sur un modèle à thinking dès qu'on touche
  `/v1/chat/completions`. Sans lui, le premier token part en `reasoning_content` et ne
  porte aucune décision. `/completion` avec prompt brut n'est pas concerné.
- `--jinja` est activé par défaut dans cette build.
- `--cache-reuse N` réutilise le KV d'un préfixe stable — gros gain quand seul un
  suffixe varie d'une requête à l'autre.

## Vérifications

```bash
KUBECONFIG=~/.kube/home.dohrm kubectl -n ai-stack get pods -o wide

# ROCm bien détecté
KUBECONFIG=~/.kube/home.dohrm kubectl -n ai-stack logs deploy/qwen35b-a3b-llm-server | head -40

# Modèles présents sur le PV
KUBECONFIG=~/.kube/home.dohrm kubectl -n ai-stack exec deploy/qwen35b-a3b-llm-server -- ls /models

# API, depuis le pod
KUBECONFIG=~/.kube/home.dohrm kubectl -n ai-stack exec deploy/qwen35b-a3b-llm-server -- \
  curl -s http://127.0.0.1:8080/v1/models
```

Validation locale des manifestes (KSOPS ne tourne pas en local, mais un overlay seul
se construit) :

```bash
kubectl kustomize applications/ai-stack/overlays/<nom>
```

## Pannes courantes

| Symptôme | Cause |
|---|---|
| Pod en `Init:Error` | GGUF absent de `/home/michael/models/…` — le chemin du patch ne correspond pas au fichier réel |
| Pod `Pending` sans événement clair | `requests.memory` dépasse ce qui reste d'allouable sur le nœud |
| Crash au chargement mentionnant mmap | `--no-mmap` manquant |
| Probabilités absurdes ou toutes à 1.0 | `post_sampling_probs: true` dans la requête |
| Première réponse vide, contenu dans `reasoning_content` | thinking actif — `--reasoning-budget 0` |
| Déploiement d'une nouvelle app qui échoue | `ksops-generator.yaml` manquant, même sans secret (`files: []`) |
