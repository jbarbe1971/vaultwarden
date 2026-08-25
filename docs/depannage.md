# Dépannage

## Le conteneur ne démarre pas / redémarre en boucle

```bash
sudo docker logs --tail 100 vaultwarden
```

- `Permission denied (os error 13)` : droits sur le dossier de données.
  ```bash
  sudo chown -R root:root /volume1/docker/vaultwarden/data
  sudo chmod -R 750 /volume1/docker/vaultwarden/data
  ```
- `Address already in use` : le port `HTTP_PORT` est déjà pris. Vérifiez avec
  `sudo netstat -tulpn | grep 8222` et changez la valeur dans `.env`.

## « An error has occurred » / le coffre web reste bloqué au chargement

Accès en HTTP simple : les API de chiffrement du navigateur (WebCrypto) ne sont
disponibles qu'en HTTPS (ou sur `localhost`). Passez par le proxy inversé.

## Les clients ne se synchronisent pas en temps réel

En-têtes WebSocket absents du proxy inversé DSM — voir
[reverse-proxy.md](reverse-proxy.md), section 3. Depuis la version 1.29, le WebSocket
passe par le même port que le web (`/notifications/hub`) : aucun port 3012 à ouvrir.

## Les liens d'invitation ou de réinitialisation pointent vers la mauvaise adresse

`DOMAIN` ne correspond pas à l'URL publique réelle. Corrigez le `.env`, puis
`sudo docker compose up -d`.

## `/admin` renvoie « Invalid admin token »

- Le `$` du hash Argon2 n'a pas été doublé dans le `.env` (`$$argon2id$$v=19$$...`).
- Ou le jeton est vide → la page d'administration est désactivée, c'est volontaire.

## Les e-mails ne partent pas

```bash
sudo docker logs vaultwarden | grep -i smtp
```

- Gmail / Microsoft 365 : utilisez un **mot de passe d'application**, jamais le mot de
  passe du compte.
- Port 587 → `SMTP_SECURITY=starttls` ; port 465 → `SMTP_SECURITY=force_tls`.
- Le NAS doit pouvoir sortir sur ce port (certains FAI bloquent le 25).

## Erreur de certificat Let's Encrypt lors de la création

Le port 80 externe n'arrive pas au NAS : vérifiez la redirection sur la box et qu'aucun
autre service (autre proxy, Web Station) ne l'accapare.

## Après une mise à jour, les données semblent perdues

Vérifiez que le volume pointe toujours vers `DATA_PATH` :

```bash
sudo docker inspect vaultwarden --format '{{json .Mounts}}'
```

Si le montage a changé, corrigez `docker-compose.yml` et relancez : les données sont
intactes dans l'ancien dossier. En dernier recours, restaurez :

```bash
sudo bash scripts/restore-vaultwarden.sh /volume1/docker/vaultwarden/backups/vaultwarden-*.tar.gz
```

## Réinitialiser un mot de passe maître oublié

Impossible côté serveur : le coffre est chiffré de bout en bout avec ce mot de passe.
Depuis `/admin`, on peut seulement supprimer le compte (et donc son contenu), ou
utiliser l'**accès d'urgence** si un contact de confiance a été configuré au préalable.

## fail2ban ne bannit personne

```bash
sudo docker exec vaultwarden-fail2ban fail2ban-client status vaultwarden
sudo docker logs --tail 50 vaultwarden-fail2ban
```

- `Currently failed: 0` alors que les échecs s'accumulent : le journal n'est pas lu.
  Vérifiez le montage `-v .../data:/vaultwarden:ro` et l'existence de
  `data/vaultwarden.log` (variable `LOG_FILE`).
- Les échecs sont comptés mais aucun bannissement : toutes les IP journalisées sont
  `127.0.0.1` (donc dans `ignoreip`). L'en-tête `X-Real-IP` manque dans le proxy inversé
  DSM, ou `IP_HEADER` ne correspond pas à cet en-tête.
- `iptables: Permission denied` : les capacités `NET_ADMIN` / `NET_RAW` ou
  `network_mode: host` ont été perdues lors d'une modification du compose.
- Les chaînes `f2b-*` ont disparu après une modification du pare-feu DSM :
  `sudo docker restart vaultwarden-fail2ban`.

## Je me suis fait bannir par fail2ban

Depuis le NAS (SSH en LAN, jamais banni grâce à `ignoreip`) :

```bash
sudo docker exec vaultwarden-fail2ban fail2ban-client set vaultwarden unbanip VOTRE_IP
```

En dernier recours, arrêtez le conteneur : `sudo docker stop vaultwarden-fail2ban`.
