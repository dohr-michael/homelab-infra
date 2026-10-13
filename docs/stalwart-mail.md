# Stalwart — serveur mail de dohrm.com

## Décision (2026-10-12)

Stalwart **v0.16.26** sert **dohrm.com** uniquement. **dohrm.fr reste entièrement
chez OVH** (5 boîtes, dont des boîtes familiales) : son MX n'est pas touché.

| Option écartée | Raison |
|---|---|
| Split delivery sur dohrm.fr (MX → Stalwart, inconnus relayés vers OVH) | Stalwart devient le point unique de défaillance des boîtes OVH |
| MX dohrm.fr chez OVH, redirections vers Stalwart | Pas de catch-all OVH : une redirection par adresse, double saut, SPF cassé |
| Caddy termine tout le TLS | Impossible pour SMTP 25/587 : STARTTLS se négocie dans la session SMTP |
| Certificat de Caddy partagé avec Stalwart | Stalwart ne relit pas un certificat modifié sur disque : rechargement manuel à chaque renouvellement |
| RocksDB sur PVC local | PostgreSQL CNPG est déjà sauvegardé (Barman → S3) ; aucun volume à gérer |
| Annuaire OIDC Zitadel | Les clients IMAP/SMTP ne gèrent pas OAUTHBEARER avec un IdP auto-hébergé |
| `/admin` filtré au tailnet | Cosmétique : l'administration passe par l'API JMAP (`/jmap`), la même que celle des clients |

## Architecture

| Élément | Choix |
|---|---|
| Nœud | `vps-a7c3e9b8` via `role.homelab/mail` (`infra/label-nodes.sh`) — IP `51.178.19.49` |
| Stockage | Les 4 stores (données, blobs, recherche, cache) dans la base `stalwart` de `postgres-prod` |
| Mail | 25, 465, 587, 993 en `hostPort` ; TLS terminé par Stalwart ; IP client conservée |
| HTTPS (WebUI, JMAP, OAuth) | `https://mail.dohrm.com` : Caddy termine le TLS → Traefik → Service `:8080` |
| Certificat mail | ACME HTTP-01 géré par Stalwart ; Caddy transmet `/.well-known/acme-challenge` reçu sur 80 |
| Certificat HTTPS | Celui de Caddy pour le même nom : deux certificats indépendants |
| Configuration | `config.json` = DataStore seul (ConfigMap) ; tout le reste vit en base |

Ports vérifiés depuis Internet le 2026-10-12 : 25, 465, 587, 993 ouverts **sans
règle ufw**. Un `hostPort` est un DNAT : le trafic passe par `FORWARD`
(accepté par flannel), pas par les règles `INPUT` d'ufw.

Le cluster est **IPv4 uniquement** (`podCIDRs: 10.42.0.0/24`) : pas d'AAAA sur
`mail`, les envois sortent par `51.178.19.49`.

Budget : **100m / 256 Mi** demandés, limite **768 Mi**.

## DNS dohrm.com (OVH, hors external-dns)

Publié et vérifié le 2026-10-12 sur `dns101.ovh.net` :

```dns
@                                 IN MX  10 mail.dohrm.com.
@                                 IN TXT "v=spf1 mx -all"
_dmarc                            IN TXT "v=DMARC1; p=none; rua=mailto:postmaster@dohrm.com"
mail                              IN A   51.178.19.49
mail                              IN TXT "v=spf1 a -all"
_smtp._tls                        IN TXT "v=TLSRPTv1; rua=mailto:postmaster@dohrm.com"
_imaps._tcp                       IN SRV 0 1 993 mail.dohrm.com.
_submissions._tcp                 IN SRV 0 1 465 mail.dohrm.com.
v1-rsa-20261012._domainkey        IN TXT "v=DKIM1; k=rsa; …"
v1-ed25519-20261012._domainkey    IN TXT "v=DKIM1; k=ed25519; …"
```

PTR de `51.178.19.49` et de l'IPv6 du VPS : `mail.dohrm.com.`

Enregistrements du zone file Stalwart **volontairement non publiés** :

| Enregistrement | Raison |
|---|---|
| TLSA | Pas de DNSSEC sur dohrm.com ; avec DNSSEC, le `3 1 1` casserait la réception au renouvellement de clé |
| CAA avec `accounturi` | Interdirait à Caddy d'émettre pour `*.dohrm.com` |
| `_validation-persist` | Challenge DNS-PERSIST-01, non utilisé |
| DMARC `p=reject` | Rester en `p=none` le temps de lire les rapports |
| MTA-STS, autoconfig, autodiscover | À servir en HTTPS sur `mail.dohrm.com` : possible maintenant, pas encore fait |

## Rotation DKIM

Stalwart ne fait tourner les clés que si **il gère lui-même le DNS**. Avec un
DNS manuel, garder **DKIM management = Manual** : sinon il signe au bout de
90 jours avec une clé absente de la zone, sans alerte.

Pour la rotation automatique (API OVH) :

1. Créer un token dédié sur `https://eu.api.ovh.com/createToken/`
   (validité illimitée, IP restreinte à `51.178.19.49`), limité aux
   enregistrements de la zone :
   ```
   GET     /domain/zone/dohrm.com/record
   GET     /domain/zone/dohrm.com/record/*
   POST    /domain/zone/dohrm.com/record
   PUT     /domain/zone/dohrm.com/record/*
   DELETE  /domain/zone/dohrm.com/record/*
   POST    /domain/zone/dohrm.com/refresh
   ```
   Le token de Caddy ne couvre que `dohrm.fr` (vérifié le 2026-10-13 avec
   `GET /auth/currentCredential`) : ne pas l'élargir, une fuite de l'un ne
   doit pas toucher la zone de l'autre. Révocation : console API,
   `DELETE /me/api/credential/{id}`.
2. Ajouter les secrets au Secret existant (lu en `envFrom`) :
   ```bash
   sops applications/stalwart/stalwart.secret.yaml
   #   STALWART_OVH_APP_SECRET: <application secret>
   #   STALWART_OVH_CONSUMER_KEY: <consumer key>
   ```
   Saisis directement dans la WebUI, ces secrets finiraient en clair dans la
   base PostgreSQL, donc dans les sauvegardes Barman. Ici, Stalwart ne stocke
   que le nom de la variable. `envFrom` n'est lu qu'au démarrage : après le
   sync ArgoCD, `kubectl -n stalwart rollout restart deploy/stalwart`.
3. WebUI › Settings › Network › DNS › DNS Providers › New, type **OVH** :
   `applicationKey` en clair, `applicationSecret` et `consumerKey` en
   `EnvironmentVariable` (noms ci-dessus), endpoint `ovh-eu`.
4. Domaine `dohrm.com` : **DNS management = Automatic**, ce fournisseur,
   **`publishRecords` = `dkim` uniquement** (sinon il publie aussi CAA,
   `p=reject` et MTA-STS) ; puis **DKIM management = Automatic**.

## Caddy (hôte `vps-a7c3e9b8`, non versionné)

```caddyfile
mail.dohrm.com {
    reverse_proxy localhost:81
}

http://mail.dohrm.com {
    handle /.well-known/acme-challenge/* {
        reverse_proxy localhost:81
    }
    redir https://{host}{uri} 308
}
```

Le bloc `http://` remplace la redirection automatique de Caddy sur le port 80
pour ce nom : les challenges de Stalwart y passent, le reste est redirigé.
Caddy obtient son propre certificat en TLS-ALPN-01 sur 443.

## Mise en service (faite le 2026-10-12)

1. Label posé (`infra/label-nodes.sh`), merge, CNPG crée rôle et base.
   Le pod redémarre quelques fois si CNPG n'a pas encore créé le rôle
   (`password authentication failed`), puis se stabilise.
2. **Pas d'assistant** : avec `config.json` présent, Stalwart démarre en mode
   normal avec une configuration par défaut. Connexion avec `admin` et le mot
   de passe de `STALWART_RECOVERY_ADMIN`.
3. **Logs** : aucun tracer par défaut. Ajouter un tracer **Console** (`info`)
   et supprimer le tracer fichier (`/var/log/stalwart` n'existe pas).
4. Système : hostname `mail.dohrm.com`.
5. **ACME Provider** à créer (aucun par défaut) : Let's Encrypt, challenge
   **HTTP-01** — le défaut est TLS-ALPN-01, qui échoue sur Caddy.
6. Domaine `dohrm.com` : certificat ACME, **SAN = `mail`** (vide = wildcard,
   impossible en HTTP-01), DNS manuel, DKIM manuel.
7. Le renouvellement n'est pas lancé à la création : Tasks › New ›
   **AcmeRenewal**. Let's Encrypt peut imposer une attente (« Rate limited.
   Retry after … ») : la tâche se replanifie seule.
8. Listeners : ajouter **`submission`** (SMTP, `[::]:587`, TLS non implicite),
   absent par défaut. Supprimer `https` (443), `pop3s` (995) et `sieve`
   (4190), non exposés.
9. Listener `http` : faire confiance à `X-Forwarded-For` depuis
   `10.42.0.0/16` (Traefik, qui conserve celui de Caddy).
10. Comptes : admin permanent avec 2FA, `postmaster@dohrm.com`.
11. Retirer `STALWART_RECOVERY_ADMIN` du secret, redémarrer.

Il n'y a **pas de webmail** : `/admin` (console) et `/account` (portail
utilisateur) seulement. Clients : IMAP 993 + SMTP 587 (STARTTLS) ou 465.
Depuis la v0.16.22, l'authentification par mot de passe n'est proposée
qu'après STARTTLS.

## Vérification

```bash
openssl s_client -connect mail.dohrm.com:993 </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer
openssl s_client -connect mail.dohrm.com:587 -starttls smtp </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer
curl -s https://mail.dohrm.com/.well-known/openid-configuration | head -c 200
```

Puis un envoi vers `https://www.mail-tester.com` : SPF, DKIM, DMARC et PTR
doivent passer.

## Références

- [Kubernetes](https://stalw.art/docs/cluster/orchestration/kubernetes) ·
  [Bootstrap](https://stalw.art/docs/configuration/bootstrap-mode) ·
  [Recovery](https://stalw.art/docs/configuration/recovery-mode)
- [PostgreSQL](https://stalw.art/docs/storage/backends/postgresql) ·
  [Certificats TLS](https://stalw.art/docs/domains/tls-certificates) ·
  [Challenges ACME](https://stalw.art/docs/server/tls/acme/challenges)
- [Enregistrements DNS](https://stalw.art/docs/domains/dns-records) ·
  [Rotation DKIM](https://stalw.art/docs/domains/dkim-rotation)
- [Reverse proxy](https://stalw.art/docs/server/reverse-proxy/) ·
  [Listeners](https://stalw.art/docs/server/listener) ·
  [Applications web](https://stalw.art/docs/management/applications/)
