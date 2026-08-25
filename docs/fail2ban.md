# fail2ban pour Vaultwarden sur Synology

Vaultwarden n'a pas de limitation de tentatives intégrée : un serveur exposé sur
Internet reçoit très vite du bourrinage de mots de passe. Le blocage automatique de
DSM ne protège que les services DSM eux-mêmes — le trafic qui passe par le proxy
inversé lui échappe totalement.

La solution retenue ici : un conteneur **fail2ban** qui lit le journal de Vaultwarden
et pose des règles **iptables** sur le NAS.

```
Internet ──► 443 (nginx DSM, proxy inversé) ──► 127.0.0.1:8222 (Vaultwarden)
                    │                                    │
                    │ en-tête X-Real-IP                  │ écrit data/vaultwarden.log
                    ▼                                    ▼
              IP réelle du client ───────────────► fail2ban (network_mode: host)
                                                          │
                                                          ▼
                                              iptables -I INPUT -s IP -j REJECT
```

## Deux prisons

| Prison | Déclencheur | Seuil | Bannissement |
|---|---|---|---|
| `vaultwarden` | mot de passe erroné, code TOTP invalide | 5 échecs / 30 min | 4 h |
| `vaultwarden-admin` | jeton `/admin` invalide | 3 échecs / 30 min | 24 h |

Le bannissement est **progressif** (`bantime.increment`) : chaque récidive double la
durée, jusqu'à 30 jours.

## Prérequis indispensable : l'IP réelle

Sans en-tête transmis par le proxy, Vaultwarden journalise `127.0.0.1` pour **toutes**
les tentatives — fail2ban bannirait alors le NAS lui-même (`ignoreip` l'en empêche,
mais plus rien n'est protégé). Deux conditions :

1. Dans le proxy inversé DSM, l'en-tête personnalisé `X-Real-IP` = `$remote_addr`
   est bien présent (voir [reverse-proxy.md](reverse-proxy.md), section 3).
2. Dans le `.env`, `IP_HEADER=X-Real-IP` (valeur par défaut du `docker-compose.yml`).

Vérification, après une tentative de connexion volontairement ratée depuis un
téléphone en 4G :

```bash
sudo tail -n 20 /volume1/docker/vaultwarden/data/vaultwarden.log | grep "IP:"
```

L'adresse affichée doit être l'IP publique du téléphone, pas `127.0.0.1`.

## Installation

1. Copiez le dossier `fail2ban/` de ce dépôt dans `/volume1/docker/vaultwarden/` :

   ```
   /volume1/docker/vaultwarden/fail2ban/
   ├── filter.d/vaultwarden.conf
   ├── filter.d/vaultwarden-admin.conf
   └── jail.d/vaultwarden.local
   ```

2. Adaptez `ignoreip` dans `jail.d/vaultwarden.local` à votre plan d'adressage
   (par défaut : `127.0.0.1/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`).
   **Ne retirez jamais votre propre sous-réseau** tant que vous n'êtes pas sûr de vous.

3. Relancez le projet — le service `fail2ban` est déjà dans le `docker-compose.yml` :

   ```bash
   cd /volume1/docker/vaultwarden
   sudo docker compose up -d
   ```

   Sous Container Manager : Projet > `vaultwarden` > Action > **Reconstruire**.

Le conteneur tourne en `network_mode: host` avec les capacités `NET_ADMIN` et
`NET_RAW` : c'est ce qui lui permet d'écrire dans les chaînes iptables du NAS.
Sans cela, il démarre mais ne bannit rien.

## Vérifier que ça marche

```bash
# État général et prisons actives
sudo docker exec vaultwarden-fail2ban fail2ban-client status

# Détail d'une prison : nombre d'échecs et IP bannies
sudo docker exec vaultwarden-fail2ban fail2ban-client status vaultwarden

# Journal du conteneur
sudo docker logs --tail 50 vaultwarden-fail2ban

# Règles réellement posées sur le NAS
sudo iptables -L f2b-vaultwarden -n
```

Test grandeur nature : depuis une connexion **extérieure** (4G, pas le LAN — le LAN est
dans `ignoreip`), saisissez cinq fois un mauvais mot de passe. La sixième tentative doit
tomber en timeout, et l'IP apparaître dans `Banned IP list`.

Débannir manuellement :

```bash
sudo docker exec vaultwarden-fail2ban fail2ban-client set vaultwarden unbanip 203.0.113.7
```

Bannir manuellement (test) :

```bash
sudo docker exec vaultwarden-fail2ban fail2ban-client set vaultwarden banip 203.0.113.7
```

## Rotation du journal

`LOG_FILE` fait grossir `data/vaultwarden.log` indéfiniment. Planifiez une rotation
hebdomadaire (Planificateur de tâches DSM, utilisateur root) :

```bash
bash /volume1/docker/vaultwarden/scripts/rotate-vaultwarden-log.sh
```

Le script utilise la méthode *copytruncate* : l'inode est conservé, ni Vaultwarden ni
fail2ban n'ont besoin d'être redémarrés. Il ne fait rien tant que le fichier reste
sous 20 Mo (`MAX_SIZE_MB`) et conserve 4 archives gzip (`KEEP`).

## Limites à connaître

- **Modification du pare-feu DSM** : quand DSM réapplique ses règles, les chaînes
  `f2b-*` peuvent disparaître. Après toute modification du pare-feu, relancez le
  conteneur : `sudo docker restart vaultwarden-fail2ban`.
- **CDN / proxy en amont** (Cloudflare, tunnel) : le blocage iptables n'a alors aucun
  effet, toutes les connexions arrivant du même relais. Il faut bannir au niveau du CDN.
- **Redémarrage du NAS** : les bannissements en cours sont rechargés depuis la base
  `fail2ban.sqlite3` (conservée dans `fail2ban/db/`, purgée après `F2B_DB_PURGE_AGE`).
- fail2ban ralentit une attaque par force brute, il ne remplace ni un mot de passe
  maître solide, ni la 2FA, ni `SIGNUPS_ALLOWED=false`.
