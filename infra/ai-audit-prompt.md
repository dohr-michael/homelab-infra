# Prompt d'audit infra périodique

À brancher sur un agent planifié (Claude Code en cron, ou `/schedule`). Lecture seule :
aucune commande de ce prompt ne modifie le cluster.

Fréquence conseillée : quotidienne, le matin. Le but n'est pas de remplacer les alertes
Alertmanager — qui traitent le temps réel — mais de repérer les **dérives lentes** que
personne ne remarque : un backup qui rétrécit, un PVC qui grossit de 2 % par semaine,
une app OutOfSync depuis un mois, un CRD qui traîne une version en retard.

C'est exactement la classe de problème qui a laissé `argocd-repo-server` mort 28 jours.

---

## Prompt

```
Tu réalises l'audit quotidien du cluster K3S décrit dans /home/michael/devs/homelab-infra.
Lis d'abord CLAUDE.md et docs/critical-app-readiness.md pour le contexte et la topologie cible.

Utilise KUBECONFIG=~/.kube/home.dohrm. Reste en LECTURE SEULE : uniquement get, describe,
logs, top. Aucun apply, delete, patch, label, scale ou edit, même si tu identifies un
correctif évident — tu le proposes, tu ne l'appliques pas.

Vérifie, dans cet ordre de priorité :

1. GITOPS
   - Toutes les Applications ArgoCD sont-elles Synced et Healthy ?
   - Une Application en sync "Unknown" est une PANNE, pas un avertissement : ça veut dire
     que le repo-server ne rend plus les manifestes et que plus rien ne se déploie.
   - Le pod argocd-repo-server est-il 2/2 Running, sans restart récent ?

2. BACKUPS — le point le plus important
   - Quel est l'âge du dernier PerconaServerMongoDBBackup en state "ready", par namespace ?
   - Y en a-t-il un en state "error" ?
   - Le PITR est-il actif (status du CR psmdb) ?
   - La taille des backups est-elle cohérente avec les précédents ? Un backup qui rétrécit
     brutalement est plus inquiétant qu'un backup absent, parce qu'il ne déclenche rien.
   - Des snapshots etcd récents existent-ils, et sont-ils bien sur S3 et pas seulement en
     file:// ? (kubectl get etcdsnapshotfiles)

3. DONNÉES
   - Le RS MongoDB de prod a-t-il ses 3 membres ready, sur 3 nœuds DIFFÉRENTS ?
   - Quel est le remplissage des PVC ? Rappel : local-path-retain n'autorise PAS
     l'extension à chaud, donc une projection à 4 semaines est plus utile qu'un seuil.

4. CAPACITÉ
   - RAM et disque disponibles par nœud. Les VPS n'ont que 8 Go : signale toute marge
     sous 20 %.
   - Y a-t-il des pods sans requests/limits, ou en OOMKilled récent ?
   - La somme des requests mémoire dépasse-t-elle la capacité d'un nœud ?

5. QUORUM
   - Combien de membres etcd ? Tant que c'est 2, la perte d'un nœud rend le cluster
     indisponible : à rappeler explicitement tant que le 3ᵉ nœud OVH n'est pas là.

6. DÉRIVE
   - Des namespaces ou workloads tournent-ils hors des applications/ du repo ?
   - Des pods en CrashLoopBackOff, Pending ou Waiting depuis plus d'une heure ?
   - Des images en tag `latest` ou non épinglées ?

Rends un rapport court et hiérarchisé :

  - D'abord ce qui est CASSÉ ou va casser sous 7 jours, avec la commande de diagnostic
    correspondante.
  - Ensuite les dérives lentes, avec le chiffre et sa tendance.
  - Enfin, une seule ligne : "rien d'autre à signaler" si le reste est sain.

N'invente aucun chiffre : si une commande échoue ou ne renvoie rien, dis-le. Ne répète
pas ce que les alertes Alertmanager couvrent déjà en temps réel, sauf si l'alerte est
justement muette alors qu'elle devrait se déclencher — ce cas-là mérite d'être remonté
en priorité.
```

---

## Mise en place

```bash
# Dans une session Claude Code, au chemin du repo :
/schedule
```

Puis décrire la cadence souhaitée et coller le prompt ci-dessus. Vérifier que la session
planifiée a bien accès au kubeconfig.

Alternative sans agent planifié : exécuter le prompt à la main une fois par semaine.
L'essentiel est la régularité, pas l'automatisation.
