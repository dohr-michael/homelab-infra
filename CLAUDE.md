# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Homelab infrastructure on K3S — AI/ML stack (LLM + image gen) on AMD Strix Halo (gfx1151/Vulkan), managed via ArgoCD GitOps.

## Architecture

- **4-node K3S cluster**: 2 VPS control-planes, 1 Strix Halo GPU agent, 1 GTX1060 agent
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

## Strix Halo Requirements

- Kernel ≥ 6.18.4, firmware ≥ 20260110 (avoid 20251125)
- `--no-mmap` and `-fa` (flash attention) are mandatory for llama-server on gfx1151
- Models stored on-node at `/srv/ai-models/{llm,diffusion}`
- BIOS UMA: allocate max GPU memory (~64-88 Go)
