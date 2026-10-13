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
_jmap._tcp                        IN SRV 0 1 443 mail.dohrm.com.   # à publier
v1-rsa-20261012._domainkey        IN TXT "v=DKIM1; k=rsa; …"
v1-ed25519-20261012._domainkey    IN TXT "v=DKIM1; k=ed25519; …"
```

PTR de `51.178.19.49` et de l'IPv6 du VPS : `mail.dohrm.com.`

`_jmap._tcp` (RFC 8620) : sans lui, un client qui découvre JMAP depuis
l'adresse (Himalaya v2) ne trouve pas le serveur. Publiable depuis que
`mail.dohrm.com:443` est servi par Caddy (2026-10-13).

Les clés DKIM sont gérées par Stalwart via l'API OVH depuis le 2026-10-13
(voir « Rotation DKIM ») : ne plus les modifier à la main.

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
   GET     /domain/zone/dohrm.com
   GET     /domain/zone/dohrm.com/record
   GET     /domain/zone/dohrm.com/record/*
   POST    /domain/zone/dohrm.com/record
   DELETE  /domain/zone/dohrm.com/record/*
   POST    /domain/zone/dohrm.com/refresh
   ```
   `GET /domain/zone/dohrm.com` est indispensable : le client OVH de
   Stalwart (`dns-update`) vérifie la zone avant toute écriture, sinon
   « Zone dohrm.com not found or not accessible ». Pas de `PUT` : il
   supprime puis recrée. Les droits d'un token OVH ne se modifient pas :
   en recréer un.
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
5. Relancer la publication : Tasks › New › **DnsManagement**.
6. **Vérifier les doublons.** À l'activation (2026-10-13), Stalwart a remplacé
   la clé Ed25519 publiée à la main, mais a **ajouté** une seconde clé RSA à
   côté de la manuelle (découpage des chaînes différent). Supprimer la
   manuelle chez OVH : plusieurs TXT DKIM sur un même sélecteur peuvent faire
   échouer la vérification.
   ```bash
   dig +short TXT v1-rsa-20261012._domainkey.dohrm.com @dns101.ovh.net | grep -c DKIM1   # attendu : 1
   ```

## Caddy (hôte `vps-a7c3e9b8`, copie dans `infra/caddy/Caddyfile`)

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
9. **Settings › HTTP Server › Proxy** : activer « Obtain remote IP from
   Forwarded header » (`useXForwarded`). Ne **pas** renseigner
   `proxyTrustedNetworks` : il active le Proxy Protocol, que Traefik n'envoie
   pas en HTTP.
10. **Settings › Security › Allowed IPs** : `10.42.0.0/16` (réseau des pods).
   Indispensable, voir l'incident du 2026-10-13.
11. Comptes : admin permanent avec **2FA** (seule protection de la WebUI
   contre la force brute, voir l'incident), `postmaster@dohrm.com`.
12. Retirer `STALWART_RECOVERY_ADMIN` du secret, redémarrer.

Il n'y a **pas de webmail** : `/admin` (console) et `/account` (portail
utilisateur) seulement. Clients : IMAP 993 + SMTP 587 (STARTTLS) ou 465.
Depuis la v0.16.22, l'authentification par mot de passe n'est proposée
qu'après STARTTLS.

## Incident du 2026-10-13 : Traefik banni, 502 pour tous

**Symptôme.** `https://mail.dohrm.com` renvoie 502 quelques heures après
l'exposition publique. Logs Stalwart :
`Blocked IP address (security.ip-blocked) listenerId = "http", remoteIp = 10.42.1.24`
— l'IP du pod Traefik.

**Cause.** Sans `useXForwarded`, Stalwart attribue toutes les requêtes HTTP à
Traefik. Les robots qui scannent les chemins d'exploit (`*.php*`, `*/wp-*`,
`*xmlrpc*`…, bannis à la première requête) ont fait bannir Traefik ;
Stalwart coupe alors chaque connexion et Traefik répond 502.

**Rétablissement.**

1. La WebUI publique est inaccessible et la connexion OAuth repasse par
   `https://mail.dohrm.com`. Accès direct au listener HTTPS interne de
   Stalwart (443, certificat Let's Encrypt de `mail.dohrm.com`), depuis le
   Mac : la connexion vient de `127.0.0.1`, non bannie.
   ```bash
   echo "127.0.0.1 mail.dohrm.com" | sudo tee -a /etc/hosts
   kubectl --kubeconfig="$HOME/.kube/home.dohrm" -n stalwart port-forward deploy/stalwart 443:443
   ```
   Pas besoin de `sudo` pour le port 443 sur macOS. Avec `sudo`, écrire
   `--kubeconfig="$HOME/…"` : zsh ne développe pas `~` dans
   `sudo KUBECONFIG=~/…`, et kubectl retombe sur `localhost:8080`.
   Firefox en DNS-over-HTTPS peut ignorer `/etc/hosts`.
2. Supprimer l'entrée `10.42.x.x` dans Security › Blocked IPs.
3. **Redémarrer le pod** : la liste des IP bloquées est aussi tenue en
   mémoire, la suppression en base ne suffit pas.
4. Retirer la ligne de `/etc/hosts`.

**Point non résolu.** Même avec `useXForwarded` activé, les événements
`auth.success` du listener HTTP affichent toujours `remoteIp = 10.42.1.24`.
Soit le log montre l'IP TCP, soit l'en-tête n'est pas pris en compte (non
tranché : un test avec un faux `X-Forwarded-For` sur `/wp-login.php` a reçu
un 302 sans déclencher de ban). D'où la liste blanche `10.42.0.0/16` :
Traefik ne peut plus être banni. Contrepartie : si l'en-tête est ignoré, la
force brute sur la WebUI n'est pas bannie — la 2FA admin compense.
SMTP et IMAP ne sont pas concernés : `hostPort` conserve l'IP réelle, et
l'auto-ban bloque bien les scanners de ports (5 IP publiques dès le premier
jour, et des tentatives de spam vers des adresses inexistantes).

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
