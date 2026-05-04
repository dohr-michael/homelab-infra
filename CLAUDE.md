# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Homelab infrastructure on K3S — AI/ML stack (LLM + image gen) on AMD Strix Halo (gfx1151/ROCm), managed via ArgoCD GitOps.

## Architecture

- **4-node K3S cluster**: 2 VPS control-planes, 1 Strix Halo GPU agent (`gmk-ai-master`), 1 GTX1060 agent
- **GTX 1060 node**: hors K3S — services systemd (ex: `whisper-server.service`), exposés au cluster via `Service` headless + `Endpoints` pointant sur l'IP Headscale du noeud (ex: `100.64.0.5`)
- **ArgoCD** (`argocd/`): GitOps controller, deployed via `kubectl apply -k argocd/`
- **ApplicationSet**: auto-discovers apps in `applications/*/` and deploys them
- **Secrets**: SOPS + age encryption, decrypted at deploy time by a KSOPS CMP sidecar on the ArgoCD repo-server

## Key Commands

```bash
# Deploy/update ArgoCD
kubectl apply -k argocd/ --kubeconfig=~/.kube/home.dohrm

# Encrypt a secret before commit
sops --encrypt --in-place <path>.secret.yaml

# Edit an encrypted secret (decrypts in-place, re-encrypts on save)
sops <path>.secret.yaml

# Build sd-cpp-vulkan image locally
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
- **GPU workloads** need `nodeSelector: gpu-type: strix-halo` + `toleration: dedicated=ai:NoSchedule`
- **Deployment strategy**: `Recreate` for GPU pods (shared GPU, no rolling update)
- **AppProject**: `homelab` — restricts to `https://github.com/dohr-michael/*` repos
- **Base domain**: `home.dohrm.fr` (behind Caddy, VPN-only via Headscale)

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

## AI Stack — Structure LLM

Le LLM est déployé via un pattern **base + overlays** :

- `applications/ai-stack/base/llm.yaml` : Deployment/Service template générique
- `applications/ai-stack/overlays/<model>/` : 1 overlay = 1 modèle déployé, avec son propre `ConfigMap` (`MODEL_PATH`, `CTX_SIZE`, `PARALLEL_SLOTS`)
- Les overlays sont référencés dans `applications/ai-stack/kustomization.yaml` sous `resources:`

Actuellement déployés : `overlays/gemma4` (Gemma 4 26B), `overlays/nomic` (embeddings).

Pour ajouter un modèle : créer un nouvel overlay avec `namePrefix`, `labels.app`, et le `configMapGenerator` correspondant.

## Strix Halo — Backend GPU

- **LLM** : ROCm — image `kyuz0/amd-strix-halo-toolboxes:rocm-7.2`, accès `/dev/dri` + `/dev/kfd`
- **Image gen (sd-server)** : Vulkan — image custom buildée depuis `Dockerfile.sd-cpp`, accès `/dev/dri`
- `securityContext: privileged: true, runAsUser: 0` **obligatoire** pour ROCm (SELinux bloque les allocations mémoire HSA)
- Modèles stockés sur le noeud : `/srv/ai-models/{llm,diffusion}`

### Flags llama-server obligatoires sur gfx1151

- `--no-mmap` : évite les crashs mmap sur gfx1151
- `-fa 1` : flash attention (performances)
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
