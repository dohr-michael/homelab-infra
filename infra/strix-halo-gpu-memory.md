# Strix Halo — Augmenter la mémoire GPU via GRUB

Le Strix Halo utilise une architecture mémoire unifiée : la RAM système est
partagée entre le CPU et le GPU. Le BIOS contrôle l'allocation UMA (VRAM dédiée),
mais on peut augmenter la mémoire accessible au GPU via les paramètres GRUB.

## Architecture mémoire

```
RAM totale (ex: 96 Go)
├── VRAM (UMA BIOS)     → mémoire dédiée GPU, rapide
├── GTT (configurable)  → RAM système mappée pour le GPU, un peu plus lent
└── Système             → OS, K3S, applications
```

## Paramètres GRUB recommandés

Ajouter à `GRUB_CMDLINE_LINUX` dans `/etc/default/grub` :

```
amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856
```

| Paramètre | Valeur | Effet |
|---|---|---|
| `amd_iommu=off` | off | Désactive l'IOMMU AMD (évite les conflits mémoire GPU) |
| `amdgpu.gttsize=126976` | 126976 Mo (~124 Go) | Taille max du GTT (RAM système accessible au GPU) |
| `ttm.pages_limit=32505856` | ~124 Go en pages | Limite de pages TTM (Translation Table Manager) |

## Application sur le node gmk-ai-master

```bash
# 1. Editer la config GRUB
sudo vi /etc/default/grub

# Modifier la ligne GRUB_CMDLINE_LINUX :
GRUB_CMDLINE_LINUX="rd.lvm.lv=fedora/root rhgb quiet amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856"

# 2. Regénérer la config GRUB
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

# 3. Redémarrer
sudo reboot
```

## Vérification après reboot

```bash
# Vérifier les paramètres boot
cat /proc/cmdline

# Vérifier la mémoire GPU
cat /sys/class/drm/card0/device/mem_info_vram_total   # VRAM (UMA BIOS)
cat /sys/class/drm/card0/device/mem_info_gtt_total    # GTT (GRUB)

# Vérifier dans un container ROCm
podman run --rm --device /dev/dri --device /dev/kfd \
  --security-opt label=disable \
  docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-6.4.4 \
  rocminfo | grep -A5 "Pool"
```

## Estimation mémoire GPU par modèle

| Modèle | VRAM |
|---|---|
| Qwen3-30B-A3B Q4_K_M | ~17.5 Go |
| SDXL Turbo FP16 | ~6.5 Go |
| HunyuanVideo 1.5 | ~25-30 Go |
| Wan 2.2 14B | ~20-25 Go |

## Notes

- Le GTT est plus lent que la VRAM UMA mais permet de charger des modèles plus gros
- Avec UMA 48 Go + GTT 124 Go, le GPU peut accéder à ~172 Go (limité par la RAM physique)
- Pour les workloads actuels (Qwen3 + SDXL Turbo ≈ 24 Go), le UMA seul suffit
- Ces paramètres sont utiles pour les modèles vidéo (HunyuanVideo, Wan 2.2)
