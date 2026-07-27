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
GRANT ALL ON "telegraf" TO "telegraf"
GRANT ALL ON "speedtest" TO "telegraf"
exit
```

> ⚠️ Le user `telegraf` a besoin de **ALL** (pas READ) sur la DB `telegraf` car il **écrit**
> les métriques système. Avec READ seul, Telegraf échoue avec `403 Forbidden`.

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

## 4. Mettre à jour les datasources Grafana

Après activation de l'auth InfluxDB, les datasources Grafana ne peuvent plus se connecter.
Il faut ajouter les credentials via l'API Grafana :

```bash
# Datasource "InfluxDB" (speedtest)
curl -sf -X PUT -u admin:"$GF_SECURITY_ADMIN_PASSWORD" \
  -H 'Content-Type: application/json' \
  http://127.0.0.1:3000/api/datasources/1 \
  -d '{"name":"InfluxDB","type":"influxdb","access":"proxy","url":"http://influxdb:8086","database":"speedtest","user":"'"$INFLUXDB_USER"'","secureJsonData":{"password":"'"$INFLUXDB_USER_PASSWORD"'"},"isDefault":true}'

# Datasource "Telegraf"
curl -sf -X PUT -u admin:"$GF_SECURITY_ADMIN_PASSWORD" \
  -H 'Content-Type: application/json' \
  http://127.0.0.1:3000/api/datasources/2 \
  -d '{"name":"Telegraf","type":"influxdb","access":"proxy","url":"http://influxdb:8086","database":"telegraf","user":"'"$INFLUXDB_USER"'","secureJsonData":{"password":"'"$INFLUXDB_USER_PASSWORD"'"},"isDefault":false}'
```

> ⚠️ Sans cette étape, les dashboards Grafana affichent "No data".
> `just test` détecte ce problème via les checks "Datasource connectivity".

---

## 5. Vérifier le déploiement

```bash
# Sanity check
just check

# Tests de régression complets (19 checks incluant connectivité datasources)
just test

# Vérifier que les ports ne sont plus exposés sur 0.0.0.0
ss -tlnp | grep -E '3000|8888'
# Attendu : 127.0.0.1:3000 et 127.0.0.1:8888 uniquement
```

---

## 6. Accès distant (optionnel)

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

## 7. Vérification du docker-socket-proxy

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

## Pièges connus

### Chronograf crash avec `permission denied`

Avec `cap_drop: ALL`, le container Chronograf (qui tourne en root par défaut) perd
`DAC_OVERRIDE` et ne peut plus accéder à ses fichiers BoltDB (UID 999).
**Fix** : ajouter `user: '999:999'` dans `docker-compose.yml`.

### Telegraf `403 Forbidden`

Le user `telegraf` a besoin de `GRANT ALL` (pas `GRANT READ`) sur la DB `telegraf`
car il **écrit** les métriques système.

### Datasources Grafana "No data"

Après activation de l'auth InfluxDB, les datasources existantes n'ont pas de credentials.
Il faut les mettre à jour via l'API (étape 4).

### GitHub Pages ne se met pas à jour après push

Si le repo est configuré avec `build_type: workflow` (Source: GitHub Actions),
les pushes sur `gh-pages` ne déclenchent pas de rebuild.
**Fix** : passer en `build_type: legacy` (Source: Deploy from a branch) :

```bash
echo '{"build_type":"legacy","source":{"branch":"gh-pages","path":"/"}}' | \
  gh api repos/<owner>/<repo>/pages --method PUT --input -
```

Le script `publish-gh-pages.sh` inclut aussi un fichier `.nojekyll` pour
bypass le build Jekyll (qui peut ignorer certains fichiers).

---

## Checklist

- [ ] `.env` mis à jour avec les 6 variables (4 InfluxDB + 2 Grafana)
- [ ] Admin user InfluxDB créé manuellement (si base existante)
- [ ] User `telegraf` avec `ALL` sur `telegraf` **et** `speedtest`
- [ ] `just deploy` exécuté
- [ ] Datasources Grafana mises à jour avec credentials InfluxDB
- [ ] `just check` — 4/4 services healthy
- [ ] `just test` — 19/19 checks (incluant connectivité datasources)
- [ ] Ports vérifiés bindés sur 127.0.0.1
- [ ] Métriques Docker visibles dans Telegraf
- [ ] GitHub Pages `build_type: legacy` configuré
- [ ] Accès Grafana fonctionnel (SSH tunnel ou reverse proxy)
