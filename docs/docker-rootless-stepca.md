# Docker rootless sur Ubuntu, compatible step-ca

`scripts/install-docker-rootless-ubuntu.sh` installe **Docker Engine + Docker Compose v2
en mode rootless** sur un serveur Ubuntu (22.04 / 24.04) et le rend exploitable par des
**identités temporaires** distribuées par **step-ca** (certificats SSH de courte durée,
comptes créés à la volée par l'annuaire).

En rootless, le démon tourne sous un compte non privilégié dans un espace de noms
utilisateur : une évasion de conteneur ne donne pas root sur l'hôte. Pour un service
comme Vaultwarden, qui détient tous les mots de passe de l'organisation, c'est le mode
de fonctionnement à privilégier.

---

## 1. Le problème que résout le script

Docker rootless dépend d'éléments **attachés au compte Unix** :

| Élément | Emplacement | Problème avec une identité temporaire |
|---|---|---|
| Plages `subuid` / `subgid` | `/etc/subuid`, `/etc/subgid` | Absentes : un compte créé à la connexion n'en a pas |
| Session `systemd --user` | `/run/user/<uid>` | Détruite à la déconnexion sans *linger* |
| État du démon | `~/.local/share/docker` | Perdu si le HOME est volatile |
| Unité `docker.service` utilisateur | `~/.config/systemd/user` | Idem |

Un compte éphémère issu de step-ca ne survit pas à ces quatre points. Le script propose
donc deux modèles, au choix.

### Mode `shared` (défaut) — recommandé pour un hôte Vaultwarden

Un **compte de service permanent** (`dockersvc`) porte le démon rootless. Sa socket est
publiée une seconde fois dans `/run/docker-rootless/docker.sock`, accessible au groupe
`docker-rootless` :

```
identité temporaire (groupe docker-rootless)
        │  DOCKER_HOST=unix:///run/docker-rootless/docker.sock
        ▼
  dockerd rootless  ──  uid dockersvc  ──  état persistant dans /var/lib/dockersvc
```

Aucun état ne dépend de l'utilisateur connecté : les conteneurs continuent de tourner
entre deux sessions, et une identité qui disparaît n'emporte rien avec elle.

> **Portée du droit accordé.** Un membre du groupe `docker-rootless` peut tout faire
> *dans le périmètre de `dockersvc`* (y compris monter le HOME de `dockersvc`, donc les
> données Vaultwarden). Il n'obtient **pas** root sur l'hôte, contrairement au groupe
> `docker` d'une installation classique. Réservez ce groupe aux administrateurs du
> service.

### Mode `per-user` — cloisonnement par identité

Chaque utilisateur obtient **son propre démon**. Un helper root
(`/usr/local/sbin/docker-rootless-provision-user`, appelé via `sudo` sans mot de passe
pour les membres du groupe) réalise à la première connexion :

1. l'allocation d'une plage `subuid`/`subgid` libre (sous verrou `flock`) ;
2. la création de `/var/lib/docker-rootless/<user>`, **data-root hors du HOME** — l'état
   survit donc à un HOME éphémère ;
3. `loginctl enable-linger` puis `dockerd-rootless-setuptool.sh install`.

Les conteneurs d'un utilisateur sont invisibles des autres. En contrepartie, chaque
identité consomme un démon et son propre stockage d'images.

---

## 2. Utilisation

```bash
# Mode partagé, sans step-ca
sudo ./scripts/install-docker-rootless-ubuntu.sh

# Mode partagé + confiance step-ca + certificats SSH acceptés par sshd
sudo ./scripts/install-docker-rootless-ubuntu.sh \
    --ca-url https://ca.exemple.lu:8443 \
    --ca-fingerprint 6e6d0b2c…f2 \
    --configure-sshd

# Un démon par identité temporaire
sudo ./scripts/install-docker-rootless-ubuntu.sh --mode per-user \
    --ca-url https://ca.exemple.lu:8443 --ca-fingerprint 6e6d0b2c…f2

# Voir ce qui serait fait, sans rien modifier
sudo ./scripts/install-docker-rootless-ubuntu.sh --dry-run
```

Options principales (`--help` pour la liste complète) :

| Option | Rôle |
|---|---|
| `--mode shared\|per-user` | Modèle d'accès (défaut : `shared`) |
| `--user`, `--group` | Compte de service et groupe autorisé |
| `--port-start N` | `net.ipv4.ip_unprivileged_port_start` (défaut 80, donc 80/443 utilisables) |
| `--port-driver` | `slirp4netns` (défaut, IP source réelle) ou `builtin` (plus rapide) |
| `--ca-url` / `--ca-fingerprint` | Bootstrap step-ca + ajout de la racine au magasin système |
| `--ca-root FICHIER` | Racine PEM déjà en votre possession, sans appeler la CA |
| `--configure-sshd` | `TrustedUserCAKeys` pointant sur la CA SSH utilisateur de step-ca |
| `--keep-rootful` | Conserve le démon Docker privilégié (déconseillé) |
| `--dry-run` | Affiche les actions sans les exécuter |

Le script est **idempotent** : on peut le rejouer pour changer un paramètre.

---

## 3. Ce qu'il fait, étape par étape

1. **Prérequis** : `uidmap` (newuidmap/newgidmap), `dbus-user-session`, `fuse-overlayfs`,
   `slirp4netns`, `passt`, `iptables`, `jq`, `acl`.
2. **Noyau** : chargement des modules netfilter, `net.ipv4.ip_unprivileged_port_start`,
   `user.max_user_namespaces`, et — sur Ubuntu 23.10+ — un **profil AppArmor** autorisant
   `userns` pour `rootlesskit` (la restriction globale des user namespaces reste active).
3. **Docker** : dépôt officiel `download.docker.com`, paquets `docker-ce`, `docker-ce-cli`,
   `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`,
   `docker-ce-rootless-extras`.
4. **Démon privilégié désactivé** (`systemctl mask docker.service docker.socket`) sauf
   `--keep-rootful` : la machine n'expose plus de socket root-equivalent.
5. **Mode choisi** : compte de service + socket de groupe, ou helper de provisionnement.
6. **step-ca** : `step-cli`, `step ca bootstrap --install`, racine ajoutée à
   `/usr/local/share/ca-certificates` (registres privés en HTTPS, `step ca certificate`),
   et confiance sshd optionnelle.
7. **`/etc/profile.d/docker-rootless.sh`** : exporte le bon `DOCKER_HOST` pour les membres
   du groupe — c'est ce qui rend l'expérience transparente pour une identité temporaire.

---

## 4. Donner l'accès à une identité step-ca

L'appartenance au groupe `docker-rootless` est le seul droit à distribuer.

- Comptes locaux : `sudo usermod -aG docker-rootless alice`
- Comptes éphémères : faites porter l'appartenance par votre annuaire / le provisionneur
  qui crée le compte à la connexion (SSSD, `pam_mkhomedir`, script `AuthorizedKeysCommand`,
  etc.). Le script ne crée pas d'utilisateurs : il ne fait aucune hypothèse sur la manière
  dont vos identités apparaissent sur la machine.

Vérification côté utilisateur, après reconnexion :

```bash
id -nG | tr ' ' '\n' | grep docker-rootless
echo "$DOCKER_HOST"
docker info | head
docker compose version
```

### Côté sshd

`--configure-sshd` écrit `/etc/ssh/sshd_config.d/60-step-ca.conf` avec la seule directive
`TrustedUserCAKeys`. C'est **additif** : les clés publiques et mots de passe existants
restent valables, et la configuration est validée par `sshd -t` avant rechargement (en cas
d'erreur, le fichier est supprimé et rien n'est rechargé). Gardez malgré tout une session
SSH ouverte pendant l'opération.

Le script ne touche pas à `AuthorizedPrincipalsFile` : mal configurée, cette directive
verrouille l'accès. Si vous mappez des *principals* vers des comptes, ajoutez-la vous-même
après avoir testé.

---

## 5. Points d'attention en rootless

- **Ports** : avec `--port-start 80`, les conteneurs publient directement 80/443. Sinon,
  publiez 8080/8443 et laissez le proxy inversé faire la traduction.
- **IP source des clients** : c'est la raison du défaut `--port-driver slirp4netns`. Avec
  le pilote `builtin`, toutes les connexions entrantes apparaissent comme venant de
  `127.0.0.1` — les logs Vaultwarden et **fail2ban deviennent inexploitables**.
- **Stockage** : `overlay2` sur `fuse-overlayfs` (ou noyau ≥ 5.11). Les volumes NFS et
  `--net=host` complet ne sont pas gérés comme en rootful.
- **Limites de ressources** (`cpus`, `mem_limit`) : nécessitent cgroup v2 + systemd, ce qui
  est le cas d'Ubuntu 22.04+.
- **Sauvegardes** : en mode `shared`, les volumes vivent sous `/var/lib/dockersvc`.
  Adaptez `scripts/backup-vaultwarden.sh` en conséquence (et exécutez-le avec le
  `DOCKER_HOST` du groupe, pas en root).

### Déployer Vaultwarden sur cette base

```bash
sudo install -d -o dockersvc -g docker-rootless -m 2750 /srv/vaultwarden
sudo cp docker-compose.yml .env /srv/vaultwarden/
sudo chown dockersvc:docker-rootless /srv/vaultwarden/{docker-compose.yml,.env}
sudo chmod 640 /srv/vaultwarden/.env      # ADMIN_TOKEN, identifiants SMTP
cd /srv/vaultwarden && docker compose up -d
```

Le `.env` doit rester lisible par le compte de service uniquement ; les chemins de volumes
du `docker-compose.yml` doivent appartenir à `dockersvc`.

---

## 6. Dépannage

| Symptôme | Piste |
|---|---|
| `Cannot connect to the Docker daemon` | Reconnectez-vous (le `DOCKER_HOST` vient de `/etc/profile.d`), puis vérifiez `id -nG` |
| `permission denied` sur la socket | L'identité n'est pas dans `docker-rootless`, ou la socket n'a pas été recréée : redémarrez le démon |
| `newuidmap: uid range not found` | Ligne absente dans `/etc/subuid`/`/etc/subgid` — rejouez le script (ou le helper en mode `per-user`) |
| `rootlesskit: failed to setup UID/GID map` | Restriction AppArmor : vérifiez `/etc/apparmor.d/usr.bin.rootlesskit` et `systemctl restart apparmor` |
| Le démon s'arrête à la déconnexion | `loginctl enable-linger <user>` |
| Toutes les IP clientes sont `127.0.0.1` | Pilote de port `builtin` : rejouez avec `--port-driver slirp4netns` |

Journaux du démon :

```bash
# mode shared
sudo machinectl shell dockersvc@ /bin/bash -c 'journalctl --user -u docker -n 100'
# mode per-user (en tant que l'utilisateur concerné)
journalctl --user -u docker -n 100
```

## 7. Revenir en arrière

```bash
# arrêter et supprimer le démon rootless du compte de service
sudo runuser -u dockersvc -- env XDG_RUNTIME_DIR=/run/user/$(id -u dockersvc) \
     dockerd-rootless-setuptool.sh uninstall
sudo loginctl disable-linger dockersvc

# retirer les fichiers déposés par le script
sudo rm -f /etc/profile.d/docker-rootless.sh /etc/tmpfiles.d/docker-rootless.conf \
           /etc/sysctl.d/99-docker-rootless.conf /etc/modules-load.d/docker-rootless.conf \
           /etc/sudoers.d/docker-rootless /usr/local/sbin/docker-rootless-provision-user \
           /etc/ssh/sshd_config.d/60-step-ca.conf
sudo rm -rf /etc/systemd/user/docker.service.d

# réactiver éventuellement le démon privilégié
sudo systemctl unmask docker.service docker.socket && sudo systemctl enable --now docker
```
