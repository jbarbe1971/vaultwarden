# Vaultwarden sur NAS Synology

Kit de déploiement de **Vaultwarden** (serveur Bitwarden non officiel, léger, écrit en Rust
et compatible avec toutes les applications Bitwarden officielles) sur un NAS Synology
sous **DSM 7.x** avec **Container Manager**.

> Le serveur *Bitwarden* officiel demande ~2 Go de RAM, plusieurs conteneurs et une clé
> d'installation. Vaultwarden fait la même chose dans un seul conteneur d'environ 200 Mo,
> ce qui correspond bien mieux à un NAS. Les clients (navigateur, iOS, Android, bureau)
> restent les applications Bitwarden officielles.

## Contenu du dépôt

| Fichier | Rôle |
|---|---|
| `docker-compose.yml` | Définition du conteneur (à coller dans Container Manager) |
| `.env.example` | Toutes les variables à personnaliser — à copier en `.env` |
| `scripts/backup-vaultwarden.sh` | Sauvegarde cohérente (base + clés + pièces jointes), avec rotation |
| `scripts/restore-vaultwarden.sh` | Restauration d'une archive de sauvegarde |
| `docs/reverse-proxy.md` | Proxy inversé DSM + certificat Let's Encrypt, pas à pas |
| `docs/depannage.md` | Erreurs fréquentes et solutions |

## Prérequis

- NAS Synology compatible Docker (séries x86 : DS220+, DS224+, DS723+, DS923+… ;
  les modèles ARM d'entrée de gamme type DS120j/DS223j **ne** supportent **pas** Container Manager).
- DSM 7.2 ou supérieur, paquet **Container Manager** installé (Centre de paquets).
- Un dossier partagé `docker` (créé automatiquement par Container Manager).
- Un nom de domaine accessible depuis Internet : DDNS Synology gratuit
  (`monnas.synology.me`) ou votre propre domaine.
- Les ports **80** et **443** de votre box redirigés vers le NAS (le 80 sert uniquement
  au renouvellement du certificat Let's Encrypt).

> ⚠️ **Le HTTPS est obligatoire.** Le coffre web et les extensions utilisent l'API
> WebCrypto, indisponible en HTTP simple. Un accès uniquement en `http://192.168.1.x:8222`
> permet de tester, mais ne permet pas d'utiliser réellement le coffre.

---

## 1. Préparer l'arborescence

En SSH (Panneau de configuration > Terminal & SNMP > Activer SSH), ou via File Station :

```bash
sudo mkdir -p /volume1/docker/vaultwarden/{data,backups,scripts}
```

Copiez `docker-compose.yml`, `.env` et le dossier `scripts/` dans
`/volume1/docker/vaultwarden/`.

## 2. Configurer le `.env`

```bash
cp .env.example .env
```

À adapter en priorité :

| Variable | Valeur |
|---|---|
| `DOMAIN` | `https://vault.mondomaine.lu` — l'URL publique **exacte**, sans `/` final |
| `DATA_PATH` | `/volume1/docker/vaultwarden/data` |
| `HTTP_PORT` | `8222` (ports libres uniquement : DSM occupe 80, 443, 5000, 5001, 7000-7001) |
| `SIGNUPS_ALLOWED` | `true` pour créer votre compte, puis `false` |
| `ADMIN_TOKEN` | jeton haché (voir plus bas) ou vide pour désactiver `/admin` |

Générer un `ADMIN_TOKEN` haché (recommandé : il n'est plus stocké en clair) :

```bash
sudo docker run --rm -it vaultwarden/server:latest-alpine /vaultwarden hash
```

Collez la chaîne `$argon2id$v=19$...` dans le `.env` **en doublant chaque `$`**
(`$$argon2id$$v=19$$...`), sinon docker compose l'interprète comme une variable.

## 3. Déployer

### Via Container Manager (interface DSM)

1. **Container Manager > Projet > Créer**
2. Nom du projet : `vaultwarden`
3. Chemin : `/volume1/docker/vaultwarden` (choisir le dossier existant)
4. Source : *Créer docker-compose.yml* → coller le contenu du fichier, ou
   *Utiliser un fichier docker-compose.yml existant* si vous l'avez déjà copié
5. Suivant > Terminé. L'image est téléchargée puis le conteneur démarre.

### Via SSH

```bash
cd /volume1/docker/vaultwarden
sudo docker compose up -d
sudo docker compose logs -f
```

Test local : `http://IP_DU_NAS:8222` doit afficher la page de connexion Bitwarden.

## 4. HTTPS et proxy inversé

Voir **[docs/reverse-proxy.md](docs/reverse-proxy.md)** : certificat Let's Encrypt via DSM,
proxy inversé `vault.mondomaine.lu` → `localhost:8222`, en-têtes WebSocket
(obligatoires pour la synchronisation temps réel).

## 5. Créer le compte et verrouiller le serveur

1. Ouvrez `https://vault.mondomaine.lu`, créez votre compte.
2. Activez la double authentification (TOTP) dans les paramètres du compte.
3. Repassez `SIGNUPS_ALLOWED=false` dans le `.env`, puis :
   ```bash
   sudo docker compose up -d
   ```
   (ou Container Manager > Projet > *Générer* / *Action > Reconstruire*).
4. Les utilisateurs supplémentaires se créent ensuite par **invitation**
   (`INVITATIONS_ALLOWED=true` + SMTP configuré), ou depuis `/admin`.

## 6. Sauvegardes

Le NAS n'est pas une sauvegarde : perdre `data/` (base **et** `rsa_key.pem`) signifie
perdre le coffre. Deux niveaux :

**a) Snapshot applicatif (ce dépôt)** — Panneau de configuration >
*Planificateur de tâches* > Créer > Tâche planifiée > Script défini par l'utilisateur,
utilisateur **root**, tous les jours à 3 h :

```bash
bash /volume1/docker/vaultwarden/scripts/backup-vaultwarden.sh
```

Archives dans `/volume1/docker/vaultwarden/backups/`, rétention 30 jours
(`RETENTION_DAYS`).

**b) Copie hors NAS** — Hyper Backup vers un disque USB, un autre NAS ou un stockage
distant, en incluant `/volume1/docker/vaultwarden/backups`. Testez une restauration
au moins une fois :

```bash
sudo bash scripts/restore-vaultwarden.sh /volume1/docker/vaultwarden/backups/vaultwarden-AAAAMMJJ-HHMMSS.tar.gz
```

## 7. Mises à jour

```bash
cd /volume1/docker/vaultwarden
sudo bash scripts/backup-vaultwarden.sh   # toujours sauvegarder avant
sudo docker compose pull
sudo docker compose up -d
sudo docker image prune -f
```

En production, épinglez la version dans `.env` (`VW_VERSION=1.34.3-alpine`) plutôt que
`latest-alpine`, et lisez les notes de version avant chaque montée de version :
<https://github.com/dani-garcia/vaultwarden/releases>.

## Sécurité — l'essentiel

- HTTPS uniquement, certificat valide ; ne jamais exposer le port `8222` sur Internet.
- 2FA activée sur tous les comptes, mot de passe maître long et unique.
- `SIGNUPS_ALLOWED=false` une fois les comptes créés.
- `ADMIN_TOKEN` haché, ou `/admin` désactivé et réservé aux cas exceptionnels.
- Pare-feu DSM actif (Panneau de configuration > Sécurité > Pare-feu) : n'autoriser
  80/443 que depuis Internet, l'administration DSM depuis le LAN uniquement.
- Blocage automatique DSM activé, et éventuellement fail2ban sur `data/vaultwarden.log`.
- Si vous préférez ne rien exposer : accès via **VPN** (paquet DSM *VPN Server*
  ou Tailscale) — dans ce cas `DOMAIN` doit pointer vers un nom résolu en HTTPS
  à l'intérieur du VPN.

## Ressources

- Wiki Vaultwarden : <https://github.com/dani-garcia/vaultwarden/wiki>
- Variables d'environnement : <https://github.com/dani-garcia/vaultwarden/blob/main/.env.template>
- Clients Bitwarden : <https://bitwarden.com/download/>
