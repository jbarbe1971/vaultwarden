# HTTPS : certificat et proxy inversé DSM

Objectif : `https://vault.mondomaine.lu` (443, public) → `http://localhost:8222`
(le conteneur Vaultwarden, non exposé).

## 1. Nom de domaine

### Option A — DDNS Synology (gratuit)

Panneau de configuration > **Accès externe** > **DDNS** > Ajouter :

- Fournisseur de services : `Synology`
- Nom d'hôte : `monnas` → donne `monnas.synology.me`
- Adresse e-mail : votre compte Synology
- Cochez **Obtenir un certificat de Let's Encrypt** et **Activer le HSTS**

DSM crée le certificat automatiquement et le renouvelle tout seul.

### Option B — Votre propre domaine

1. Chez votre registrar, créez un enregistrement `A` (ou `CNAME` vers le DDNS)
   `vault.mondomaine.lu` → IP publique de votre box.
2. Panneau de configuration > **Sécurité** > **Certificat** > Ajouter >
   *Obtenir un certificat de Let's Encrypt* :
   - Nom de domaine : `vault.mondomaine.lu`
   - E-mail : le vôtre
   - (Autres noms : ajoutez ici d'éventuels sous-domaines supplémentaires)

> Le port **80** doit être redirigé vers le NAS pendant la validation, sinon
> Let's Encrypt échoue (`Failed to connect`).

## 2. Redirection de ports sur la box / le routeur

| Port externe | Vers | Port interne |
|---|---|---|
| 80 (TCP) | IP du NAS | 80 |
| 443 (TCP) | IP du NAS | 443 |

Ne redirigez **jamais** le port 8222, ni les ports d'administration DSM (5000/5001).

## 3. Proxy inversé

Panneau de configuration > **Portail de connexion** > onglet **Avancé** >
**Proxy inversé** > Créer :

**Source**
- Protocole : `HTTPS`
- Nom d'hôte : `vault.mondomaine.lu`
- Port : `443`
- Activer HSTS : coché
- HTTP/2 : coché

**Destination**
- Protocole : `HTTP`
- Nom d'hôte : `localhost`
- Port : `8222`

**Onglet « En-tête personnalisé »** > Créer > **WebSocket** : DSM ajoute
automatiquement les deux en-têtes nécessaires :

| Nom | Valeur |
|---|---|
| `Upgrade` | `$http_upgrade` |
| `Connection` | `$connection_upgrade` |

Ajoutez également, via *Créer > En-tête personnalisé* :

| Nom | Valeur |
|---|---|
| `X-Forwarded-For` | `$proxy_add_x_forwarded_for` |
| `X-Real-IP` | `$remote_addr` |

Ces deux en-têtes ne sont **pas optionnels si vous utilisez fail2ban** : sans eux,
Vaultwarden journalise `127.0.0.1` pour toutes les tentatives et le bannissement
devient inopérant (voir [fail2ban.md](fail2ban.md)).

Sans les en-têtes WebSocket, tout fonctionne mais la synchronisation temps réel entre
appareils ne se déclenche qu'au rafraîchissement manuel.

## 4. Associer le certificat

Panneau de configuration > **Sécurité** > **Certificat** > **Paramètres** :
en face du service `vault.mondomaine.lu`, sélectionnez le certificat Let's Encrypt
correspondant, puis *Appliquer*.

## 5. Vérifications

```bash
curl -I https://vault.mondomaine.lu/alive        # 200 OK
curl -s https://vault.mondomaine.lu/api/config   # JSON de configuration
```

Puis dans un navigateur : cadenas valide, page de connexion Bitwarden, et dans
l'application mobile Bitwarden > *Paramètres de l'environnement autohébergé* >
`https://vault.mondomaine.lu`.

Le `DOMAIN` du `.env` doit correspondre **exactement** à cette URL (schéma, sous-domaine,
pas de `/` final), sinon les invitations, les liens Send et les passkeys échouent.
