# 🚀 Stack AI sur K3S — AMD Strix Halo (Vulkan)

Stack complète pour exécuter des LLMs et de la génération d'images sur un noeud AMD Strix Halo (gfx1151) via **Vulkan**, déployée sur K3S.

## Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │         Cluster K3S (4 noeuds)              │
                    │                                             │
┌──────────┐       │  ┌─────────────────────────────────────────┐ │
│          │       │  │  Noeud Strix Halo (96 Go RAM partagée)  │ │
│  Client  │───────│──│                                         │ │
│ navigateur       │  │  ┌──────────────┐  ┌─────────────────┐  │ │
│          │       │  │  │ llama-server  │  │  sd-cpp-vulkan  │  │ │
└──────────┘       │  │  │ (Qwen3 30B)  │  │  (SDXL Turbo)   │  │ │
                   │  │  │ Vulkan :8080  │  │  Vulkan  :7860  │  │ │
                   │  │  └──────┬───────┘  └───────┬─────────┘  │ │
                   │  │         └──────┬───────────┘            │ │
                   │  │           /dev/dri (iGPU Vulkan)        │ │
                   │  └─────────────────────────────────────────┘ │
                   │                                             │
                   │  ┌──────────────────────────┐               │
                   │  │  Open WebUI (tout noeud)  │               │
                   │  │  :3000                    │               │
                   │  └──────────────────────────┘               │
                   └─────────────────────────────────────────────┘
```

## Prérequis

### Sur le noeud Strix Halo

#### 1. Kernel ≥ 6.18.4
```bash
uname -r
# Si < 6.18.4, mettre à jour — les kernels plus anciens ont un bug gfx1151
```

#### 2. Firmware
```bash
# ⚠️ NE PAS utiliser linux-firmware-20251125 (casse ROCm/Vulkan)
# Utiliser ≥ 20260110 ou une version antérieure stable
rpm -q linux-firmware
```

#### 3. Vérifier Vulkan
```bash
vulkaninfo --summary
# Doit afficher : AMD Radeon Graphics (RADV GFX1151)
```

#### 4. Labels et taints du noeud
```bash
# Label pour le nodeSelector
kubectl label node <NOM_NOEUD_STRIX> gpu-type=strix-halo

# Taint pour réserver le noeud aux workloads AI
kubectl taint node <NOM_NOEUD_STRIX> dedicated=ai:NoSchedule
```

#### 5. BIOS — Allocation mémoire GPU
Dans le BIOS de la GMKTech, allouer le maximum de mémoire au GPU (UMA).
Idéalement : **~80-88 Go GPU / ~8-16 Go système**.

#### 6. Créer les répertoires de modèles
```bash
sudo mkdir -p /srv/ai-models/{llm,diffusion}
sudo chown -R 1000:1000 /srv/ai-models
```

### Télécharger les modèles

#### LLM — Qwen3-30B-A3B-Instruct (MoE)
```bash
# Option A : Q4_K_M (~10 Go) — bon compromis qualité/taille
# Laisse beaucoup de place pour la génération d'images
curl -L -o /srv/ai-models/llm/Qwen3-30B-A3B-Instruct-Q4_K_M.gguf \
  "https://huggingface.co/Qwen/Qwen3-30B-A3B-Instruct-GGUF/resolve/main/qwen3-30b-a3b-instruct-q4_k_m.gguf"

# Option B : BF16 (~17 Go) — qualité maximale, plus lent
# huggingface-cli download unsloth/Qwen3-30B-A3B-Instruct-GGUF \
#   BF16/Qwen3-30B-A3B-Instruct-BF16-00001-of-00002.gguf \
#   --local-dir /srv/ai-models/llm/

# Option C : Qwen3-32B dense Q4_K_M (~20 Go) — si vous préférez un modèle dense
# curl -L -o /srv/ai-models/llm/Qwen3-32B-Q4_K_M.gguf \
#   "https://huggingface.co/Qwen/Qwen3-32B-GGUF/resolve/main/qwen3-32b-q4_k_m.gguf"
```

#### Image Gen — SDXL Turbo
```bash
curl -L -o /srv/ai-models/diffusion/sd_xl_turbo_1.0_fp16.safetensors \
  "https://huggingface.co/stabilityai/sdxl-turbo/resolve/main/sd_xl_turbo_1.0_fp16.safetensors"
```

## Déploiement

### Étape 1 — Builder l'image stable-diffusion.cpp
```bash
# Sur une machine avec Docker (peut être le noeud Strix Halo)
cd docker/
docker build -t sd-cpp-vulkan:latest -f Dockerfile.sd-cpp .

# Si vous avez un registry privé :
docker tag sd-cpp-vulkan:latest <votre-registry>/sd-cpp-vulkan:latest
docker push <votre-registry>/sd-cpp-vulkan:latest
# → Puis modifier l'image dans 20-sd-server.yaml

# Si pas de registry, importer directement dans K3S (sur le noeud) :
docker save sd-cpp-vulkan:latest | sudo k3s ctr images import -
```

### Étape 2 — Appliquer les manifestes
```bash
# Tout d'un coup
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-storage.yaml
kubectl apply -f 10-llama-server.yaml
kubectl apply -f 20-sd-server.yaml
kubectl apply -f 30-open-webui.yaml

# Optionnel : Ingress pour accès externe
kubectl apply -f 40-ingress.yaml
```

### Étape 3 — Vérifier le déploiement
```bash
# Statut des pods
kubectl -n ai-stack get pods -w

# Logs llama-server (vérifier que Vulkan est détecté)
kubectl -n ai-stack logs -f deployment/llama-server
# Chercher : "ggml_vulkan: Found 1 Vulkan devices"
# Chercher : "AMD Radeon Graphics (RADV GFX1151)"

# Logs sd-server
kubectl -n ai-stack logs -f deployment/sd-server

# Logs Open WebUI
kubectl -n ai-stack logs -f deployment/open-webui
```

### Étape 4 — Accéder à l'interface
```bash
# Port-forward rapide (sans Ingress)
kubectl -n ai-stack port-forward svc/open-webui 3000:3000

# Ouvrir http://localhost:3000
# Créer un compte admin au premier accès
```

## Configuration Open WebUI

Après le premier login dans Open WebUI :

1. **LLM** : Aller dans `Settings → Connections`
   - L'URL OpenAI devrait déjà être configurée via les variables d'env
   - Vérifier que les modèles Qwen3 apparaissent

2. **Image Generation** : Aller dans `Settings → Images`
   - Engine : `AUTOMATIC1111`
   - URL : `http://sd-server.ai-stack.svc.cluster.local:7860`
   - Activer "Image Generation"
   - Configurer la résolution (512x512 pour SDXL Turbo)

## Test rapide des APIs

```bash
# ── Test LLM (depuis un pod du cluster) ──────────────────
curl http://llama-server.ai-stack.svc.cluster.local:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3",
    "messages": [{"role": "user", "content": "Bonjour, qui es-tu ?"}],
    "max_tokens": 100
  }'

# ── Test Image Gen ───────────────────────────────────────
curl http://sd-server.ai-stack.svc.cluster.local:7860/sdapi/v1/txt2img \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "a beautiful sunset over mountains",
    "steps": 4,
    "width": 512,
    "height": 512
  }'
```

## Budget mémoire (96 Go partagée)

| Composant                    | RAM GPU estimée |
|------------------------------|----------------|
| Qwen3-30B-A3B Q4_K_M        | ~10-12 Go      |
| KV Cache (ctx 8192, 2 slots) | ~2-4 Go        |
| SDXL Turbo FP16              | ~6.5 Go        |
| Overhead système + Vulkan    | ~4-6 Go        |
| **Total estimé**             | **~25-30 Go**  |
| **Disponible restant**       | **~60-65 Go**  |

> Vous avez largement de la marge ! Vous pourriez monter en Qwen3-32B dense
> ou utiliser un modèle de diffusion plus gros (Flux.1, etc.)

## Troubleshooting

### Le pod llama-server ne démarre pas
```bash
# Vérifier que /dev/dri est accessible
kubectl -n ai-stack exec -it deployment/llama-server -- ls -la /dev/dri/

# Vérifier Vulkan dans le conteneur
kubectl -n ai-stack exec -it deployment/llama-server -- vulkaninfo --summary
```

### Crash avec "mmap" errors
Vérifier que `--no-mmap` est bien passé en argument. C'est **obligatoire** sur gfx1151.

### Performances faibles
- Vérifier que `-fa` (flash attention) est activé
- Vérifier l'allocation mémoire GPU dans le BIOS
- Vérifier la version du kernel (≥ 6.18.4)
- Monitorer avec `amdgpu_top` sur le noeud hôte

### Open WebUI ne voit pas les modèles
```bash
# Tester l'API directement
kubectl -n ai-stack exec -it deployment/open-webui -- \
  curl http://llama-server:8080/v1/models
```

## Fichiers

```
k3s-ai-stack/
├── 00-namespace.yaml        # Namespace ai-stack
├── 01-storage.yaml          # PV/PVC pour les modèles
├── 10-llama-server.yaml     # LLM : llama.cpp Vulkan + Qwen3
├── 20-sd-server.yaml        # Image Gen : sd.cpp Vulkan
├── 30-open-webui.yaml       # Interface Web unifiée
├── 40-ingress.yaml          # Ingress (optionnel)
├── docker/
│   └── Dockerfile.sd-cpp    # Build de l'image sd.cpp Vulkan
└── README.md                # Ce fichier
```
