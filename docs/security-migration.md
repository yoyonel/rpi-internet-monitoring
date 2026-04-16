# Security Hardening — Migration Guide (RPi)

Ce document décrit les étapes à effectuer **sur le RPi** après merge de la branche `security/hardening` pour finaliser le déploiement des correctifs de sécurité.

## Pré-requis

Les modifications de code sont déjà appliquées. Il reste la configuration runtime et la migration des données.

---

## 1. Mettre à jour `.env`

Ajouter les nouvelles variables InfluxDB **avant** de relancer la stack :

```bash
# Éditer .env sur le RPi
nano .env
```

Ajouter :

```env
INFLUXDB_ADMIN_USER=admin
INFLUXDB_ADMIN_PASSWORD=<mot_de_passe_fort>
INFLUXDB_USER=telegraf
INFLUXDB_USER_PASSWORD=<mot_de_passe_fort>
```

> ⚠️ Les mots de passe doivent être **différents** et **forts** (≥ 16 caractères, mixtes).

---

## 2. Créer l'utilisateur admin InfluxDB (base existante)

Si InfluxDB tourne déjà **sans authentification**, il faut créer l'admin user manuellement
**avant** d'activer `INFLUXDB_HTTP_AUTH_ENABLED=true` :

```bash
# Depuis le RPi, sur la stack actuelle (encore sans auth)
docker exec -it influxdb influx

# Dans le shell InfluxDB :
CREATE USER admin WITH PASSWORD '<même_mot_de_passe_que_INFLUXDB_ADMIN_PASSWORD>' WITH ALL PRIVILEGES
CREATE USER telegraf WITH PASSWORD '<même_mot_de_passe_que_INFLUXDB_USER_PASSWORD>'
GRANT READ ON "telegraf" TO "telegraf"
GRANT ALL ON "speedtest" TO "telegraf"
exit
```

---

## 3. Redéployer la stack

```bash
git pull origin security/hardening
just deploy
```

Cela va :

- Rebuilder l'image `speedtest` (non-root, install sécurisée)
- Créer le container `docker-socket-proxy`
- Activer l'authentification InfluxDB
- Binder Grafana/Chronograf sur `127.0.0.1` uniquement
- Appliquer les hardening Docker (cap_drop, no-new-privileges)

---

## 4. Vérifier le déploiement

```bash
# Sanity check
just check

# Tests de régression complets
just test

# Vérifier que les ports ne sont plus exposés sur 0.0.0.0
ss -tlnp | grep -E '3000|8888'
# Attendu : 127.0.0.1:3000 et 127.0.0.1:8888 uniquement
```

---

## 5. Accès distant (optionnel)

Grafana et Chronograf sont maintenant bindés sur `localhost` uniquement.
Pour y accéder depuis un autre poste :

**Option A — SSH tunnel** (recommandé, zéro config) :

```bash
# Depuis le poste client
ssh -L 3000:127.0.0.1:3000 -L 8888:127.0.0.1:8888 user@rpi
# Puis ouvrir http://localhost:3000 dans le navigateur
```

**Option B — Reverse proxy avec TLS** :
Ajouter Caddy ou Traefik dans le `docker-compose.yml` avec certificats Let's Encrypt pour un accès HTTPS direct.

---

## 6. Vérification du docker-socket-proxy

Telegraf utilise maintenant un proxy Docker socket au lieu d'un accès direct.
Vérifier que les métriques Docker remontent :

```bash
# Attendre ~30s après le deploy, puis :
docker exec influxdb influx \
    -username admin -password '<INFLUXDB_ADMIN_PASSWORD>' \
    -execute "SELECT COUNT(*) FROM docker_container_cpu WHERE time > now() - 5m" \
    -database telegraf
```

Si 0 résultats : vérifier les logs de `docker-socket-proxy` et `telegraf` :

```bash
just logs-svc docker-socket-proxy
just logs-svc telegraf
```

---

## Checklist

- [ ] `.env` mis à jour avec les 4 variables InfluxDB
- [ ] Admin user InfluxDB créé manuellement (si base existante)
- [ ] `just deploy` exécuté
- [ ] `just check` — 4/4 services healthy
- [ ] `just test` — 0 failures
- [ ] Ports vérifiés bindés sur 127.0.0.1
- [ ] Métriques Docker visibles dans Telegraf
- [ ] Accès Grafana fonctionnel (SSH tunnel ou reverse proxy)
