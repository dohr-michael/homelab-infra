# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project

Homelab infrastructure on K3S, managed via ArgoCD GitOps. Inférence LLM actuelle : **Ollama sur l’hôte GMK** (AMD Strix Halo gfx1151), hors workloads Kubernetes.

## Architecture

Cluster K3S (k3s `v1.34.3`) — 4 nœuds enregistrés :

| Nœud | IP Headscale | Rôle |
|------|----------------|------|
| `vps-a7c3e9b8` | `100.64.0.1` | control-plane + etcd. Caddy (entrée `*.home.dohrm.fr`), Headscale |
| `vps-17435151` | `100.64.0.3` | control-plane + etcd. Taint `CriticalAddonsOnly=true:NoSchedule` |
| `vps-4541d883` | `100.64.0.11` | control-plane + etcd. ArgoCD (`role.homelab/platform`) |
| `gmk-ai-master` | `100.64.0.4` | agent GPU Strix Halo. Taint `dedicated=ai:NoSchedule`, label `gpu-type=strix-halo`. RustFS + monitoring (`role.homelab/rustfs`, `role.homelab/monitoring`) |

MongoDB prod : replica set sur les 3 VPS (`role.homelab/mongodb-prod`). PostgreSQL prod : CloudNativePG 1.30, 1 instance (`role.homelab/postgres-prod`, aujourd’hui `vps-4541d883`). Labels de nœuds : `infra/label-nodes.sh`.

- **GMK / LLM** : Ollama tourne **sur l’hôte**, pas comme Deployment K3S. Exposé hors cluster (VPN). **Inaccessible depuis les pods** — pas de Service cluster pour l’instant. Suite prévue : `Service` + `Endpoints` (ou ExternalName) vers l’URL Ollama, même pattern que whisper / ComfyUI.
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

État GitOps actuel (`applications/ai-stack/kustomization.yaml`) : **seul le namespace est déployé**. Storage, overlays LLM, whisper, sd-server, Open WebUI et ingress sont commentés.

Ancien chemin in-cluster (llama-server ROCm, **plus utilisé**) — conservé dans le repo, dormant :

- `applications/ai-stack/base/llm.yaml` : template Deployment/Service
- Overlays : `overlays/gemma4` (Gemma 4 26B), `overlays/bge-m3` (embeddings)
- Pour réactiver un overlay : le décommenter sous `resources:` (et le reste de la stack si besoin)

Chemin actuel : **Ollama sur `gmk-ai-master`**, hors cluster. Les pods ne peuvent pas l’appeler. Brancher plus tard un Service cluster sur l’URL Ollama.

Open WebUI (`30-open-webui.yaml`, non déployé) pointait encore vers `gemma4-llm-server` / `bge-m3-llm-server` in-cluster, avec `OLLAMA_BASE_URL` vide.

## Strix Halo — matériel GPU

Toujours vrai pour Ollama (et ComfyUI) **sur l’hôte** GMK.

- Accès GPU : `/dev/dri` + `/dev/kfd` (ROCm)
- Un pod ROCm in-cluster exigait `securityContext: privileged: true, runAsUser: 0` (SELinux bloque les allocs HSA)
- Modèles historiquement sur le nœud : `/srv/ai-models/{llm,diffusion}`

### Flags llama-server (gfx1151) — si le chemin in-cluster revient

- `--no-mmap` : évite les crashs mmap sur gfx1151
- `-fa 1` : flash attention
- `-ngl 999` : offload tous les layers GPU

### Mémoire GPU (UMA unifiée)

| Source | Taille | Config |
|--------|--------|--------|
| VRAM UMA (BIOS) | ~48 Go | Allouer le max dans le BIOS |
| GTT (GRUB) | ~124 Go | `amdgpu.gttsize=126976 ttm.pages_limit=32505856` |
| **Total accessible GPU** | **~172 Go** | Limité par RAM physique |

Params GRUB à ajouter dans `GRUB_CMDLINE_LINUX` : `amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856`

Voir `infra/strix-halo-gpu-memory.md` pour la procédure complète.

### Kernel et firmware

- Kernel ≥ 6.18.4 (bug gfx1151 sur les versions antérieures)
- Firmware ≥ 20260110 — **NE PAS utiliser** `linux-firmware-20251125` (casse ROCm/Vulkan)
