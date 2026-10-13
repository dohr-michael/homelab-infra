# Caddy — entrée publique

Caddy tourne **sur l'hôte** `vps-a7c3e9b8` (`51.178.19.49`, `100.64.0.1`),
hors du cluster. Il termine le TLS public et relaie vers Traefik
(`localhost:81`), Headscale (`localhost:8080`) ou des hôtes du tailnet.

`Caddyfile` est une **copie de référence** de `/etc/caddy/Caddyfile`. Rien ne
la déploie : modifier ici et sur l'hôte dans le même geste.

```bash
# Comparer avec l'hôte
ssh <hôte vps-a7c3e9b8> 'sudo cat /etc/caddy/Caddyfile' | diff - infra/caddy/Caddyfile

# Appliquer sur l'hôte
sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

## Certificats

| Bloc | Émission |
|---|---|
| `*.dohrm.fr`, `*.home.dohrm.fr`, `vpn`, `amp`, `ozzie` | DNS-01 via le token OVH `dohrm.fr` (`import ovh_auth`) |
| `tinypaw.fr` | DNS-01 via le token OVH du compte tinypaw (`import ovh_auth_jess`) |
| `mail.dohrm.com` | TLS-ALPN-01 sur 443 (le token ne couvre pas `dohrm.com`) |

Le token `ovh_auth` a les droits `GET`/`POST /domain/zone/dohrm.fr/record`,
`DELETE …/record/*` et `POST …/refresh` (vérifié le 2026-10-13).

## Variables d'environnement

Lues par le service systemd ; le fichier n'est pas encore versionné (à faire
en `*.secret.*` chiffré SOPS). Noms attendus : voir l'en-tête du `Caddyfile`.

## Vers une HA multi-VPS

Ce fichier est indépendant de l'hôte, sauf trois points à traiter pour le
dupliquer sur un autre VPS :

- `localhost:81` et `localhost:8080` supposent Traefik (klipper-lb) et
  Headscale sur la même machine. Traefik écoute sur tous les nœuds ;
  Headscale non.
- Le stockage des certificats est local (`/var/lib/caddy`). Plusieurs
  instances doivent partager un stockage (module de stockage Caddy) ou
  émettre chacune les leurs, en surveillant les limites Let's Encrypt.
- `mail.dohrm.com` est lié à `51.178.19.49` (MX, PTR, hostPort Stalwart) :
  il ne bouge pas avec Caddy.
