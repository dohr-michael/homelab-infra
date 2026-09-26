# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project

Homelab infrastructure on K3S, managed via ArgoCD GitOps. Inférence LLM actuelle : **llama.cpp ROCm in-cluster** sur `gmk-ai-master` (AMD Strix Halo gfx1151), exposée par LiteLLM.

## Architecture

Cluster K3S (k3s `v1.34.3`) — 4 nœuds enregistrés :

| Nœud | IP Headscale | Rôle |
|------|----------------|------|
| `vps-a7c3e9b8` | `100.64.0.1` | control-plane + etcd. Caddy (entrée `*.home.dohrm.fr`), Headscale |
| `vps-17435151` | `100.64.0.3` | control-plane + etcd. Taint `CriticalAddonsOnly=true:NoSchedule` |
| `vps-4541d883` | `100.64.0.11` | control-plane + etcd. ArgoCD (`role.homelab/platform`) |
| `gmk-ai-master` | `100.64.0.4` | agent GPU Strix Halo. Taint `dedicated=ai:NoSchedule`, label `gpu-type=strix-halo`. RustFS + monitoring (`role.homelab/rustfs`, `role.homelab/monitoring`) |

MongoDB prod : replica set sur les 3 VPS (`role.homelab/mongodb-prod`). PostgreSQL prod : CloudNativePG 1.30, 1 instance (`role.homelab/postgres-prod`, aujourd’hui `vps-4541d883`). Labels de nœuds : `infra/label-nodes.sh`.

- **GMK / LLM** : llama-server ROCm tourne **dans le cluster** (namespace `ai-stack`), un Deployment par modèle via overlay. Services joignables depuis les pods, consommés par LiteLLM. Pour brancher un service **hôte** (ComfyUI, OpenClaw), pattern `Service` + `Endpoints` → rester sur `Endpoints`, ArgoCD exclut `EndpointSlice` par défaut (voir `applications/ozzie/10-service.yaml`).
- **Image gen** : ComfyUI sur l’hôte GMK, pattern `Service` + `Endpoints` → `100.64.0.4:8000` (`20-sd-server.yaml`). Idem, commenté / non déployé.
- **ArgoCD** (`argocd/`) : GitOps, `kubectl apply -k argocd/`. Version pinée `v3.3.0`.
- **ApplicationSet** : auto-découvre `applications/*/` et déploie.
- **Secrets** : SOPS + age, déchiffrés au deploy par un sidecar KSOPS CMP sur le repo-server.
- **PostgreSQL** : opérateur CloudNativePG 1.30 (`applications/cnpg-operator/`), cluster `postgres-prod` 1 instance. Une base = CR `Database` + `DatabaseRole` (voir `applications/postgres-prod/20-database.example.yaml`). Backups Barman in-tree → OVH S3.

## Key Commands

```bash
# Deploy/update ArgoCD
kubectl apply -k argocd/ --kubeconfig=~/.kube/home.dohrm

# Encrypt a secret before commit
sops --encrypt --in-place <path>.secret.yaml

# Edit an encrypted secret (decrypts in-place, re-encrypts on save)
sops <path>.secret.yaml

# Build sd-cpp-vulkan image locally (legacy ; image gen actuelle = ComfyUI hôte)
docker build -t sd-cpp-vulkan:latest -f applications/ai-stack/Dockerfile.sd-cpp applications/ai-stack/

# Bootstrap SOPS (one-time)
./infra/bootstrap-sops.sh

# Validate kustomize (without KSOPS — local kubectl doesn't support exec plugins)
kubectl kustomize argocd/
```

## Conventions

- **Secret files** must use `*.secret.yaml` suffix (matched by `.sops.yaml` creation_rules)
- **Manifests** are numbered: `00-namespace`, `01-storage`, `10-`, `20-`, `30-`, `40-ingress`
- **KSOPS generator** (`ksops-generator.yaml`) must list all `*.secret.yaml` files to decrypt
- **GPU workloads** (si un pod revient sur GMK) : `nodeSelector: gpu-type: strix-halo` + `toleration: dedicated=ai:NoSchedule`
- **Deployment strategy** : `Recreate` for GPU pods (shared GPU, no rolling update)
- **AppProject** : `homelab` — `sourceRepos: ["*"]`
- **Base domain** : `home.dohrm.fr` (Caddy sur `100.64.0.1`, VPN-only via Headscale). DNS tailnet : `applications/headscale/10-dns-sync.yaml`

## Adding a New Application

1. Create `applications/<app-name>/` with a `kustomization.yaml`
2. Add `*.secret.yaml` files if needed (encrypt with `sops`)
3. **TOUJOURS** ajouter un `ksops-generator.yaml` — même sans secrets (`files: []`) : le CMP kustomize-sops est forcé sur toutes les apps par l'ApplicationSet, sans ce fichier le déploiement échoue
4. Reference the generator in `kustomization.yaml` under `generators:`
5. Push to `main` — ArgoCD ApplicationSet auto-discovers and deploys

## Cluster Access

```bash
# Use the home kubeconfig for all cluster commands
KUBECONFIG=~/.kube/home.dohrm kubectl ...
```

## AI Stack

Déployé (`applications/ai-stack/kustomization.yaml`) : namespace, storage, et trois Deployments sur `gmk-ai-master` —

| Service | Modèle | Rôle |
|---------|--------|------|
| `qwen35b-a3b-llm-server` | Qwen3.6-35B-A3B UD-Q6_K + mmproj | chat multimodal |
| `qwen3-embedding-4b-llm-server` | Qwen3-Embedding-4B Q8_0 | embeddings (2560 dims) |
| `whisper-server` | ggml-large-v3-turbo | transcription |

`base/llm.yaml` est le template Deployment/Service ; chaque modèle est un overlay sous `overlays/` qui patche `env` et `args`. Consommateurs : `applications/litellm/20-config.yaml`.

Commenté / non déployé : `20-sd-server.yaml` (ComfyUI hôte), `30-open-webui.yaml`, `40-ingress.yaml`, et l'overlay de repli `overlays/qwen3.5-9b-decision`.

### Service de décision (chantier ouvert)

Un module Python exposera une API de décision façon OpenRouter `/api/alpha/decisions`. Cible : **Open-Jev-9B** — LoRA + **tête scalaire** + température apprise sur Qwen3.5-9B, donc **inservable par llama.cpp** (rien de tout ça n'entre dans un GGUF) ; il lui faut son serveur PyTorch, à valider en ROCm sur gfx1151.

⚠ Ne **jamais** charger un GGUF estampillé « Jev » dans `base/llm.yaml` : c'est le backbone décapité de sa tête, il se charge sans erreur et renvoie des probabilités fausses, sans trace dans les logs.

Repli prêt et désactivé : `overlays/qwen3.5-9b-decision` (même backbone servi nu, décision par logprobs du premier token).

## Strix Halo — matériel GPU

Vaut pour les pods `ai-stack` comme pour ComfyUI sur l’hôte.

- Accès GPU : `/dev/dri` + `/dev/kfd` (ROCm)
- Un pod ROCm in-cluster exigait `securityContext: privileged: true, runAsUser: 0` (SELinux bloque les allocs HSA)
- Modèles sur le nœud : **`/home/michael/models`** (PV `ai-models-llm-pv`) et `/home/michael/whisper.cpp/models` (PV `ai-models-whisper-pv`).

### Flags llama-server (gfx1151)

- `--no-mmap` : évite les crashs mmap sur gfx1151
- `-fa 1` : flash attention
- `-ngl 999` : offload tous les layers GPU

Vérifié sur ce cluster (build b10664) pour tout usage « probabilités » :

- les `logprobs` sont renvoyés **avant sampling** — valeurs identiques à `temperature` 0 et 2.0, insensibles à `top_k`. Une requête qui passe `post_sampling_probs: true` les écrase à 1.0.
- `--reasoning-budget 0` est **obligatoire** dès qu'on touche `/v1/chat/completions` sur un modèle à thinking : sans lui le premier token est du monologue (`reasoning_content`).
- `--jinja` est activé par défaut dans cette build.

### Mémoire GPU (UMA unifiée)

**Mesuré le 2026-09-26 sur `gmk-ai-master`** — le « ~172 Go » qui figurait ici était faux, il additionnait VRAM et GTT alors que les deux sont pris sur la même RAM physique :

| Mesure | Valeur |
|--------|--------|
| `MemTotal` | **92,9 Gio** |
| `MemAvailable` (3 modèles résidents) | **17,2 Gio** |
| GTT utilisé / total | 50,4 / 90,2 Gio |
| VRAM dédiée | 1 Gio |
| `requests` K8s posées / allouables | 67 / 92,9 Gio |

**La RAM est une contrainte dure.** Chiffrer avant toute proposition qui ajoute un modèle résident : une seconde instance 35B-A3B ne rentre pas, et le scheduler la refuse avant même l'OOM. Commandes :

```bash
KUBECONFIG=~/.kube/home.dohrm kubectl exec -n ai-stack deploy/qwen35b-a3b-llm-server -- \
  sh -c 'grep -E "MemTotal|MemAvailable" /proc/meminfo; cat /sys/class/drm/card*/device/mem_info_gtt_used'
```

Params GRUB à ajouter dans `GRUB_CMDLINE_LINUX` : `amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856`

Voir `infra/strix-halo-gpu-memory.md` pour la procédure complète.

### Kernel et firmware

- Kernel ≥ 6.18.4 (bug gfx1151 sur les versions antérieures)
- Firmware ≥ 20260110 — **NE PAS utiliser** `linux-firmware-20251125` (casse ROCm/Vulkan)
