# Stalwart — serveur mail de dohrm.com

## Décision (2026-10-12)

Stalwart **v0.16.26** sert **dohrm.com** uniquement. **dohrm.fr reste entièrement
chez OVH** (5 boîtes, dont des boîtes familiales) : son MX n'est pas touché.

| Option écartée | Raison |
|---|---|
| Split delivery sur dohrm.fr (MX → Stalwart, inconnus relayés vers OVH) | Stalwart devient le point unique de défaillance des boîtes OVH |
| MX dohrm.fr chez OVH, redirections vers Stalwart | Pas de catch-all OVH : une redirection par adresse, double saut, SPF cassé |
| Certificat obtenu par Caddy et partagé | Stalwart ne relit pas un certificat modifié sur disque : rechargement manuel à chaque renouvellement |
| RocksDB sur PVC local | PostgreSQL CNPG est déjà sauvegardé (Barman → S3) ; aucun volume à gérer |

## Architecture

| Élément | Choix |
|---|---|
| Nœud | `vps-a7c3e9b8` via `role.homelab/mail` (`infra/label-nodes.sh`) — IP `51.178.19.49` |
| Stockage | Les 4 stores (données, blobs, recherche, cache) dans la base `stalwart` de `postgres-prod` |
| Ports publics | 25, 465, 587, 993 en `hostPort` ; l'IP client est conservée (SPF, DMARC, auto-ban) |
| WebUI | `https://mail.home.dohrm.fr` (VPN), Caddy → Traefik → Service `:8080` |
| TLS mail | ACME HTTP-01 géré par Stalwart ; Caddy transmet `/.well-known/acme-challenge` de `mail.dohrm.com` |
| Annuaire | Interne. OIDC Zitadel écarté : les clients IMAP/SMTP ne gèrent pas OAUTHBEARER avec un IdP auto-hébergé |
| Configuration | `config.json` = DataStore seul (ConfigMap) ; tout le reste vit en base |

Budget : **100m / 256 Mi** demandés, limite **768 Mi**. Le 2026-10-12,
`vps-a7c3e9b8` était à 42 % de mémoire demandée et 72 % de mémoire utilisée.

Le cluster est **IPv4 uniquement** (`podCIDRs: 10.42.0.0/24`) : les hostPort ne
reçoivent rien en IPv6 et les envois sortent par `51.178.19.49`.

## DNS dohrm.com (OVH, hors external-dns)

| Enregistrement | Valeur | État |
|---|---|---|
| `mail` A | `51.178.19.49` | fait |
| `mail` AAAA | `2001:41d0:305:2100::46c1` | **à supprimer** : rien n'écoute en IPv6 |
| MX | `10 mail.dohrm.com.` | fait |
| TXT (apex) | `v=spf1 mx -all` | fait |
| `_dmarc` TXT | `v=DMARC1; p=none; rua=mailto:postmaster@dohrm.com` | fait |
| PTR `51.178.19.49` | `mail.dohrm.com.` | fait |
| DKIM, MTA-STS, TLS-RPT, autoconfig | zone générée par Stalwart | après le bootstrap |

## Caddy (hôte `vps-a7c3e9b8`, non versionné)

```caddyfile
http://mail.dohrm.com {
    handle /.well-known/acme-challenge/* {
        reverse_proxy localhost:81
    }
    respond 404
}
```

Le préfixe `http://` empêche Caddy de demander lui-même un certificat pour ce
nom. `mail.home.dohrm.fr` est couvert par le bloc wildcard `*.home.dohrm.fr`.

## Déploiement

1. Poser le label : `KUBECONFIG=~/.kube/home.dohrm ./infra/label-nodes.sh`.
2. Merger. Vérifier que CNPG a créé le rôle et la base **avant** le premier
   démarrage du pod (les sync waves ne séquencent pas deux Applications) :
   ```bash
   kubectl --kubeconfig=~/.kube/home.dohrm -n postgres-prod get databaserole,database stalwart
   ```
3. Le pod démarre en **mode bootstrap** : services mail inactifs, WebUI seule
   sur 8080. Accès direct, sans proxy (la doc recommande de contourner le
   proxy pendant l'assistant) :
   ```bash
   kubectl --kubeconfig=~/.kube/home.dohrm -n stalwart port-forward deploy/stalwart 8080
   ```
   `http://localhost:8080/admin`, compte `admin` et mot de passe de
   `STALWART_RECOVERY_ADMIN` (`sops -d applications/stalwart/stalwart.secret.yaml`).
4. Assistant :
   - hostname `mail.dohrm.com`, domaine `dohrm.com`, TLS automatique, DKIM activé ;
   - stockage : PostgreSQL, mêmes paramètres que `config.json`, les trois autres stores sur « Use Data Store » ;
   - annuaire interne, logs **Console**, DNS **manuel**.

   Noter l'identifiant administrateur affiché à la fin (montré une seule fois).
5. `kubectl -n stalwart rollout restart deploy/stalwart`. L'initContainer
   remet le `config.json` versionné ; le serveur démarre normalement.
6. Dans la WebUI (`https://mail.home.dohrm.fr/admin`) :
   - **ACME Provider** : `challengeType` = `Http01` ; déclencher le renouvellement.
   - **Listeners** : garder `smtp` 25, `submission` 587, `submissions` 465
     (`tlsImplicit`), `imaps` 993 (`tlsImplicit`), `http` 8080 ; supprimer ceux
     qui ne sont pas exposés (443, 143, 110, 995, 4190).
   - Listener `http` : faire confiance au `X-Forwarded-For` de `10.42.0.0/16`
     (Traefik), sinon toutes les requêtes WebUI semblent venir du proxy.
   - Créer les comptes, dont `postmaster@dohrm.com` (rapports DMARC).
   - **Domains › dohrm.com › View DNS Zone file** : publier DKIM et le reste chez OVH.
7. Retirer `STALWART_RECOVERY_ADMIN` du secret, puis redémarrer le pod.

## Vérification

```bash
# Depuis l'extérieur du cluster
openssl s_client -connect mail.dohrm.com:993 </dev/null 2>&1 | grep -E 'subject|issuer'
openssl s_client -connect mail.dohrm.com:25 -starttls smtp </dev/null 2>&1 | grep -E 'subject|issuer'
```

Puis envoyer un message à `https://www.mail-tester.com` : SPF, DKIM, DMARC et
PTR doivent passer.

## Points à valider au premier déploiement

- **Bootstrap avec `config.json` présent** : la doc décrit le bootstrap « sans
  config.json ». Si le pod démarre directement sans assistant, configurer la
  même chose en mode recovery (`STALWART_RECOVERY_MODE=1`) via la WebUI.
- **HTTP-01 sur le listener 8080** : l'Ingress suppose que Stalwart répond au
  challenge sur tout listener HTTP. Sinon, ajouter un listener HTTP dédié.
- **Pare-feu** : un `hostPort` est un DNAT ; le trafic traverse `FORWARD`
  (accepté par les règles flannel), pas les règles `INPUT` d'ufw — comme le
  svclb de Traefik. Tester les ports depuis l'extérieur avant d'ajouter des
  règles ufw.
- **IP source** : vérifier dans les logs Stalwart qu'une connexion SMTP
  entrante affiche l'IP réelle de l'expéditeur, pas une IP `10.42.x.x`.

## Références

- [Kubernetes](https://stalw.art/docs/cluster/orchestration/kubernetes) ·
  [Bootstrap](https://stalw.art/docs/configuration/bootstrap-mode) ·
  [Recovery](https://stalw.art/docs/configuration/recovery-mode)
- [PostgreSQL](https://stalw.art/docs/storage/backends/postgresql) ·
  [Certificats TLS](https://stalw.art/docs/domains/tls-certificates) ·
  [Challenges ACME](https://stalw.art/docs/server/tls/acme/challenges)
- [Reverse proxy](https://stalw.art/docs/server/reverse-proxy/) ·
  [Listeners](https://stalw.art/docs/server/listener)
