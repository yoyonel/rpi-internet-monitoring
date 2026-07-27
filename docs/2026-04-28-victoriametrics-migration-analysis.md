# Analyse de migration InfluxDB 1.8 → VictoriaMetrics

> **Date** : 28 avril 2026
> **Contexte** : Stack monitoring sur Raspberry Pi 4 (4 Go RAM, SD 64 Go)
> **Stack actuelle** : InfluxDB 1.8.10 (EOL) + Telegraf 1.38.2 + Grafana 12.4.3 + Chronograf 1.9.4
> **Alternative évaluée** : VictoriaMetrics single-node (OSS, Apache 2.0)

---

## Table des matières

1. [Résumé exécutif](#1-résumé-exécutif)
2. [Pourquoi migrer ?](#2-pourquoi-migrer-)
3. [Comparaison technique détaillée](#3-comparaison-technique-détaillée)
4. [Gains attendus sur le RPi4](#4-gains-attendus-sur-le-rpi4)
5. [Points d'intégration — Impact par composant](#5-points-dintégration--impact-par-composant)
6. [Transformation du modèle de données](#6-transformation-du-modèle-de-données)
7. [Difficultés et risques de la migration](#7-difficultés-et-risques-de-la-migration)
8. [Plan de migration détaillé](#8-plan-de-migration-détaillé)
9. [Ce qu'on perd](#9-ce-quon-perd)
10. [Ce qu'on gagne](#10-ce-quon-gagne)
11. [VictoriaMetrics vs InfluxDB 3.x — Le choix](#11-victoriametrics-vs-influxdb-3x--le-choix)
12. [Verdict et recommandation](#12-verdict-et-recommandation)

---

## 1. Résumé exécutif

VictoriaMetrics est un **candidat excellent** pour remplacer InfluxDB 1.8.10 sur
ce RPi4. Le gain principal est la **réduction drastique de la consommation RAM**
(de 300-500 Mo à ~50-100 Mo) sur un système où la mémoire est le bottleneck
principal (swap à 52%). La compatibilité native avec le line protocol InfluxDB
rend la migration des écritures quasi transparente.

**Le coût principal** : la réécriture des requêtes InfluxQL → MetricsQL pour
Grafana et le script `publish-gh-pages.sh`.

| Critère                          | Complexité      | Impact                                |
| -------------------------------- | --------------- | ------------------------------------- |
| Écritures (Telegraf + speedtest) | 🟢 Trivial      | Changer 1 URL                         |
| Lectures (Grafana dashboards)    | 🟡 Moyen        | Réécrire ~30 queries                  |
| Lectures (publish-gh-pages.sh)   | 🔴 Significatif | Réécrire l'export InfluxQL → API HTTP |
| Migration données historiques    | 🟢 Simple       | vmctl (outil dédié)                   |
| Suppression Chronograf           | 🟢 Gratuit      | vmui intégré remplace                 |
| Backup                           | 🟢 Simple       | Snapshots natifs                      |

---

## 2. Pourquoi migrer ?

### 2.1 Problèmes actuels avec InfluxDB 1.8.10

| Problème                                | Sévérité    | Détail                                                        |
| --------------------------------------- | ----------- | ------------------------------------------------------------- |
| **EOL depuis Oct 2022**                 | 🔴 Critique | Aucun patch sécurité depuis 3.5 ans. Go 1.18 avec CVE connues |
| **RAM excessive**                       | 🔴 Critique | 300-500 Mo pour ~71 séries. Le RPi4 swappe à 52%              |
| **Pas de downsampling natif**           | 🟡 Moyen    | CQ InfluxDB = complexes et fragiles                           |
| **Pas de Flux en OSS 1.x**              | 🟡 Moyen    | Transformations limitées à InfluxQL                           |
| **Chronograf = service supplémentaire** | 🟡 Moyen    | Consomme 80-150 Mo de RAM pour un usage rare                  |

### 2.2 Pourquoi VictoriaMetrics spécifiquement ?

- **Conçu pour être léger** : un seul binaire Go, ~16 Mo d'image Docker
- **Compatible InfluxDB line protocol** : Telegraf pointe sur VM sans config
- **Activement maintenu** : releases régulières (v1.142.0 au 28/04/2026)
- **Images ARM64 officielles** : Docker Hub multi-arch (linux/arm/v7 + arm64)
- **Adoption massive** : utilisé par ARNES, Brandwatch, et des centaines d'entreprises
- **Gratuit et open source** : Apache 2.0, pas de feature gating

---

## 3. Comparaison technique détaillée

### 3.1 Architecture et moteur

| Aspect           | InfluxDB 1.8.10                  | VictoriaMetrics (single-node)                                                       |
| ---------------- | -------------------------------- | ----------------------------------------------------------------------------------- |
| Langage          | Go 1.18 (EOL)                    | Go (dernière version stable)                                                        |
| Moteur stockage  | TSM (Time-Structured Merge Tree) | Custom merge tree (inspiré ClickHouse)                                              |
| Compression      | Gorilla + delta (~2-3 bytes/pt)  | Custom (~0.5-1 byte/pt)                                                             |
| Langage requêtes | InfluxQL                         | MetricsQL (superset de PromQL)                                                      |
| API d'écriture   | InfluxDB line protocol (HTTP)    | InfluxDB line protocol + Prometheus remote_write + Graphite + OpenTSDB + CSV + JSON |
| API de lecture   | `/query` (InfluxQL)              | Prometheus `/api/v1/query_range`                                                    |
| UI intégrée      | Non (nécessite Chronograf)       | **vmui** (explorateur + graphes)                                                    |
| Rétention        | Par database + retention policy  | `-retentionPeriod` global + retention filters par métrique                          |
| Downsampling     | Continuous Queries (manuelles)   | **Natif** via `-downsampling.period`                                                |
| Backups          | `influxd backup -portable`       | Snapshots instantanés (copy-on-write)                                               |
| Sécurité         | Basic auth                       | Basic auth + Bearer token + mTLS                                                    |
| Image Docker     | ~250-300 Mo (ARM64)              | **~16 Mo** (ARM64)                                                                  |
| Binaire          | ~100 Mo                          | **~16 Mo**                                                                          |

### 3.2 Consommation de ressources (estimations pour notre charge)

Notre charge : ~71 séries actives, ~4320 échantillons/jour (telegraf) + 144/jour (speedtest).

| Ressource                   | InfluxDB 1.8.10 (observé) | VictoriaMetrics (estimé) | Gain      |
| --------------------------- | ------------------------- | ------------------------ | --------- |
| **RAM idle**                | 300-500 Mo                | **50-100 Mo**            | **3-10×** |
| **RAM pic**                 | 500-800 Mo                | 100-200 Mo               | **3-5×**  |
| **CPU idle**                | ~2-5% (compaction TSM)    | ~1-2%                    | **2×**    |
| **Disk (steady-state 90j)** | ~730 Mo                   | **~200-350 Mo**          | **2-3×**  |
| **Image Docker**            | ~300 Mo                   | **~16 Mo**               | **18×**   |
| **I/O writes**              | WAL + TSM compaction      | Moins agressif           | **~2×**   |
| **Startup time**            | 5-15 s                    | **1-3 s**                | **3-5×**  |

### 3.3 Budget mémoire RPi4 — Avant vs Après

| Service                        | Avant (Mo)    | Après (Mo)    | Delta       |
| ------------------------------ | ------------- | ------------- | ----------- |
| OS + kernel + systemd          | 500           | 500           | —           |
| Docker daemon                  | 200           | 200           | —           |
| **InfluxDB → VictoriaMetrics** | **400**       | **80**        | **-320 Mo** |
| Grafana                        | 300           | 300           | —           |
| Telegraf                       | 150           | 150           | —           |
| **Chronograf → supprimé**      | **120**       | **0**         | **-120 Mo** |
| Docker-socket-proxy            | 20            | 20            | —           |
| Speedtest (pic)                | 100           | 100           | —           |
| **Total**                      | **~1 790 Mo** | **~1 350 Mo** | **-440 Mo** |
| **Marge libre (sur 4 Go)**     | **~2.2 Go**   | **~2.65 Go**  | **+20%**    |

**Impact direct** : le swap passerait de 52% à quasi 0% en usage normal.
C'est le gain le plus significatif pour la stabilité du RPi4.

---

## 4. Gains attendus sur le RPi4

### 4.1 Performance des requêtes

VictoriaMetrics est optimisé pour les scans séquentiels de séries temporelles.
Avec une meilleure compression (2-3× moins de données à lire), les requêtes
devraient être significativement plus rapides, surtout sur carte SD.

| Requête type           | InfluxDB (estimé) | VictoriaMetrics (estimé) |
| ---------------------- | ----------------- | ------------------------ |
| Speedtest 30j          | 20-50 ms          | **10-20 ms**             |
| Telegraf dashboard 1j  | 200-500 ms        | **50-150 ms**            |
| Telegraf dashboard 7j  | 500 ms-1.5 s      | **150-400 ms**           |
| Telegraf dashboard 90j | 5-15 s            | **1-4 s**                |

### 4.2 Durée de vie de la carte SD

- **Moins d'écritures** : pas de WAL séparé, compression meilleure
- **Moins de compactions** : le merge tree de VM est moins agressif que le TSM
- **Résultat** : réduction estimée de ~30-50% de l'usure I/O

### 4.3 Downsampling natif

VictoriaMetrics offre le downsampling via un simple flag :

```bash
-downsampling.period=30d:5m,90d:1h
```

Signification : après 30 jours, ne garder qu'un point par 5 minutes. Après
90 jours, qu'un point par heure. Cela remplace les Continuous Queries InfluxDB
(recommandation R2 du document `influxdb-stack-analysis.md`) de manière
transparente et sans maintenance.

---

## 5. Points d'intégration — Impact par composant

### 5.1 Telegraf (écriture) — 🟢 Trivial

**Changement** : modifier 1 ligne dans `telegraf/telegraf.conf`

```diff
 [[outputs.influxdb]]
-  urls = ["http://influxdb:8086"]
-  database = "telegraf"
+  urls = ["http://victoriametrics:8428"]
+  database = "telegraf"
```

VictoriaMetrics accepte nativement le InfluxDB line protocol sur `/write`.
Le paramètre `database` est mappé vers un label `db` dans VictoriaMetrics.
Les données arrivent avec le préfixe `{measurement}_{field}`, par exemple :
`cpu_usage_idle{cpu="cpu-total", db="telegraf"}`.

**Risque** : aucun. C'est un drop-in replacement pour l'écriture.

### 5.2 Speedtest (docker-entrypoint.sh) — 🟢 Trivial

**Changement** : modifier l'URL dans les variables d'environnement.

Le `docker-entrypoint.sh` utilise `curl` pour écrire en line protocol InfluxDB :

```bash
curl -K <(...) "${influxdb_url}/write?db=speedtest" --data-binary "speedtest,result_id=${result_id} ..."
```

VictoriaMetrics accepte exactement ce format sur le même endpoint `/write`.
Changement : remplacer `influxdb:8086` par `victoriametrics:8428`.

**Note** : les valeurs string (`server_name`, `result_id`) seront mappées comme
tags/labels. Les valeurs non-numériques dans les fields seront converties à 0
par VictoriaMetrics. Il faudra vérifier que `server_name` est bien un tag et non
un field dans le line protocol.

### 5.3 Grafana (dashboards) — 🟡 Moyen

**Changement majeur** : réécrire toutes les requêtes InfluxQL → MetricsQL.

**Avant (InfluxQL)** :

```sql
SELECT mean("usage_idle") FROM "cpu"
WHERE "cpu" = 'cpu-total' AND $timeFilter
GROUP BY time($__interval)
```

**Après (MetricsQL)** :

```promql
cpu_usage_idle{cpu="cpu-total", db="telegraf"}
```

Le mapping InfluxDB → VictoriaMetrics transforme les données ainsi :

| InfluxDB                                            | VictoriaMetrics                       |
| --------------------------------------------------- | ------------------------------------- |
| measurement `cpu`, field `usage_idle`               | metric `cpu_usage_idle`               |
| measurement `speedtest`, field `download_bandwidth` | metric `speedtest_download_bandwidth` |
| tag `cpu=cpu-total`                                 | label `cpu="cpu-total"`               |
| database `telegraf`                                 | label `db="telegraf"`                 |

**Dashboards à réécrire** (4 fichiers JSON) :

| Dashboard           | Fichier                                     | Queries estimées   |
| ------------------- | ------------------------------------------- | ------------------ |
| Docker Containers   | `grafana/dashboards/docker-containers.json` | ~8-10              |
| RPi Alerts Overview | `grafana/dashboards/rpi-alerts.json`        | ~4-6               |
| Internet Speedtest  | `grafana/dashboards/speedtest.json`         | ~3-5               |
| System Metrics      | `grafana/dashboards/system-metrics.json`    | ~10-15             |
| **Total**           |                                             | **~25-36 queries** |

**Datasource Grafana** : remplacer le datasource InfluxDB par un datasource
Prometheus pointant vers `http://victoriametrics:8428`.

**Provisioning** : modifier `grafana/provisioning/datasources/influxdb.yml` →
un seul datasource Prometheus suffit (pas besoin de séparer telegraf/speedtest,
VictoriaMetrics est un namespace global).

### 5.4 Script publish-gh-pages.sh — 🔴 Significatif

C'est le point d'intégration le plus complexe. Le script utilise la CLI `influx`
pour exécuter des requêtes InfluxQL :

```bash
QUERY="SELECT download_bandwidth, upload_bandwidth, ping_latency FROM speedtest WHERE time > now() - ${DAYS}d ORDER BY time ASC"

JSON_DATA=$("$DOCKER" exec influxdb influx \
    -username "..." -password "..." \
    -execute "$QUERY" \
    -database speedtest \
    -precision rfc3339 \
    -format json 2>/dev/null)
```

VictoriaMetrics **n'a pas de CLI** et **ne supporte pas InfluxQL pour les lectures**.
Il faut réécrire cette partie pour utiliser l'API HTTP Prometheus :

```bash
# Nouvelle approche : API HTTP VictoriaMetrics
START=$(date -d "-${DAYS} days" +%s)
END=$(date +%s)

JSON_DATA=$(curl -sf "http://victoriametrics:8428/api/v1/query_range" \
    --data-urlencode "query=speedtest_download_bandwidth" \
    --data-urlencode "start=${START}" \
    --data-urlencode "end=${END}" \
    --data-urlencode "step=600" 2>/dev/null)
```

**Complexités** :

1. Le format de sortie Prometheus (`matrix` type) est différent du format JSON
   InfluxDB → le script Python `render-template.py` et/ou le parsing dans
   `publish-gh-pages.sh` doivent être adaptés
2. Trois métriques à récupérer (download, upload, ping) = 3 requêtes ou une
   requête avec `{__name__=~"speedtest_(download_bandwidth|upload_bandwidth|ping_latency)"}`
3. Le `data.json` attendu par le frontend doit conserver le même format de sortie

**Alternative** : utiliser l'API d'export native de VictoriaMetrics
(`/api/v1/export`) qui retourne du JSON line format, potentiellement plus facile
à parser.

### 5.5 Scripts utilitaires — 🟢 Simple

| Script                 | Changement                                                                         |
| ---------------------- | ---------------------------------------------------------------------------------- |
| `scripts/backup.sh`    | Remplacer `influxd backup` par snapshot VM (`curl http://vm:8428/snapshot/create`) |
| `scripts/stats.sh`     | Remplacer les requêtes `influx -execute` par des appels API HTTP                   |
| `scripts/restore-*.sh` | Remplacer `influxd restore` par restauration snapshot                              |

### 5.6 Chronograf — 🟢 Suppression

Chronograf devient inutile : VictoriaMetrics inclut **vmui**, une interface web
intégrée accessible sur le même port (8428) qui offre :

- Explorateur de métriques
- Grapheur de requêtes
- Explorateur de cardinalité
- Top queries
- Active queries

→ **Suppression d'un service Docker** = -80-150 Mo de RAM, -1 container à gérer.

### 5.7 Environnement de simulation (sim/) — 🟡 Moyen

Les fichiers suivants doivent être adaptés :

- `sim/docker-compose.sim.yml` (remplacer service influxdb)
- `sim/.env.sim` (nouvelles variables)
- `sim/influxdb-init.iql` (plus nécessaire, VM est schemaless)
- `sim/telegraf-sim.conf` (changer URL output)

---

## 6. Transformation du modèle de données

### 6.1 Mapping automatique InfluxDB → VictoriaMetrics

VictoriaMetrics convertit les données InfluxDB line protocol automatiquement :

```
speedtest,result_id=abc123 download_bandwidth=941000000,upload_bandwidth=681000000,ping_latency=11.6
```

Devient dans VictoriaMetrics :

```
speedtest_download_bandwidth{result_id="abc123", db="speedtest"} 941000000
speedtest_upload_bandwidth{result_id="abc123", db="speedtest"} 681000000
speedtest_ping_latency{result_id="abc123", db="speedtest"} 11.6
```

### 6.2 Différences clés du modèle de données

| Aspect                | InfluxDB 1.8                   | VictoriaMetrics        |
| --------------------- | ------------------------------ | ---------------------- |
| Namespace             | database + measurement + field | metric name (global)   |
| Types de valeurs      | int, float, string, bool       | **float64 uniquement** |
| Résolution temporelle | Nanosecondes                   | **Millisecondes**      |
| Tags/Labels           | Types mixtes possibles         | **String uniquement**  |
| Schéma                | Par measurement                | Schemaless global      |
| Fields multiples      | 1 measurement = N fields       | N métriques séparées   |

### 6.3 Impact de la perte de résolution temporelle

InfluxDB stocke en nanosecondes, VictoriaMetrics en millisecondes. Pour notre
use case (échantillonnage à 20s minimum), la perte est **absolument négligeable**.
La résolution milliseconde est 50 000× plus fine que notre intervalle de collecte.

### 6.4 Impact du type float64 unique

Les fields string InfluxDB (comme `server_name` dans speedtest) seront
convertis à 0 par VictoriaMetrics. **Solution** : s'assurer que ces valeurs
sont des tags (labels) et non des fields dans le line protocol d'écriture.
Le `docker-entrypoint.sh` actuel utilise `result_id` comme tag — vérifier
que c'est bien le cas pour toutes les valeurs textuelles.

---

## 7. Difficultés et risques de la migration

### 7.1 Risques critiques

| #   | Risque                                  | Probabilité | Impact | Mitigation                                                     |
| --- | --------------------------------------- | ----------- | ------ | -------------------------------------------------------------- |
| 1   | **Réécriture queries Grafana cassée**   | Moyen       | Élevé  | Migrer dashboard par dashboard, tester chaque panel            |
| 2   | **publish-gh-pages.sh non fonctionnel** | Moyen       | Élevé  | Réécrire avec API HTTP VM, tester en preview avant bascule     |
| 3   | **Perte de données historiques**        | Faible      | Élevé  | Utiliser vmctl pour migrer, garder backup InfluxDB pendant 30j |
| 4   | **Non-numeric fields perdus**           | Moyen       | Faible | Identifier et convertir en tags avant migration                |

### 7.2 Difficultés techniques anticipées

#### D1. Pas de InfluxQL pour les lectures

C'est la difficulté #1. VictoriaMetrics ne supporte **aucune** variante d'InfluxQL
pour les requêtes. Tout doit être en MetricsQL (superset de PromQL).

**Impact** :

- 4 dashboards Grafana à réécrire
- 1 script shell (publish-gh-pages.sh) à réécrire
- 1 script shell (stats.sh) à réécrire

**Effort estimé** : 4-8h de travail

#### D2. Format de sortie JSON différent

**InfluxDB** retourne :

```json
{
  "results": [{
    "series": [{
      "name": "speedtest",
      "columns": ["time", "download_bandwidth", "upload_bandwidth", "ping_latency"],
      "values": [["2026-04-28T10:00:00Z", 941000000, 681000000, 11.6], ...]
    }]
  }]
}
```

**VictoriaMetrics** retourne (Prometheus API) :

```json
{
  "status": "success",
  "data": {
    "resultType": "matrix",
    "result": [{
      "metric": {"__name__": "speedtest_download_bandwidth"},
      "values": [[1745830800, "941000000"], ...]
    }]
  }
}
```

Le frontend (`gh-pages/app.js`, `gh-pages/lib.js`) et le build script
devront s'adapter à ce nouveau format — **OU** le script `publish-gh-pages.sh`
devra transformer la sortie VM vers le format attendu par le frontend (solution
préférée : garder le contrat du `data.json` inchangé).

#### D3. Rétention par métrique vs par database

InfluxDB a 2 databases avec des rétentions différentes :

- `speedtest` : rétention infinie
- `telegraf` : rétention 90 jours

VictoriaMetrics single-node a un **seul** flag `-retentionPeriod` global.
Pour des rétentions multiples, il faut utiliser les **retention filters**
(fonctionnalité Enterprise) ou lancer **2 instances** de VM.

**Solutions** :

1. **Accepter une rétention unique** : mettre `-retentionPeriod=10y` (les données
   speedtest sont minuscules, ~1.3 Mo/an). La volumétrie telegraf sera auto-purgée
   par VictoriaMetrics quand le downsampling natif est activé.
2. **Retention filter** (Enterprise) : `retain=90d for {db="telegraf"}`
3. **Downsampling** : `-downsampling.period=90d:1h` + rétention longue. Les données
   telegraf sont automatiquement compressées après 90j → volume négligeable.

**Recommandation** : solution 1 + 3 combinées. Rétention longue (5-10 ans) +
downsampling agressif après 90 jours. Le coût de stockage supplémentaire est
négligeable (~quelques Mo).

#### D4. Healthcheck Docker

Le healthcheck actuel utilise la CLI `influx` :

```yaml
test: ['CMD-SHELL', "influx -username ... -execute 'SHOW DATABASES' ..."]
```

VictoriaMetrics expose un endpoint `/health` :

```yaml
test: ['CMD-SHELL', 'wget -qO- http://localhost:8428/health || exit 1']
```

Plus léger et plus rapide.

#### D5. Backup et restore

Le backup InfluxDB (`influxd backup -portable`) n'est pas compatible avec VM.

VictoriaMetrics offre des **snapshots instantanés** via l'API :

```bash
# Créer un snapshot
curl http://localhost:8428/snapshot/create
# Retourne: {"status":"ok","snapshot":"20260428..."}

# Le snapshot est dans <storageDataPath>/snapshots/<name>/
# Copier avec rsync/cp pour backup
```

**Avantage** : les snapshots sont copy-on-write, quasi-instantanés et n'impactent
pas les performances. Plus simple que le backup portable InfluxDB.

---

## 8. Plan de migration détaillé

### Phase 0 — Préparation (1-2h)

1. Backup complet InfluxDB (`just backup`)
2. Documenter l'état actuel des dashboards Grafana (screenshots)
3. Lister toutes les requêtes InfluxQL utilisées (dashboards + scripts)
4. Créer branche `feature/victoriametrics-migration`

### Phase 1 — VictoriaMetrics en parallèle (2-3h)

1. Ajouter le service VictoriaMetrics au `docker-compose.yml` **en parallèle**
   d'InfluxDB (les deux tournent simultanément)
2. Configurer Telegraf en **dual-write** (écrire vers InfluxDB ET VictoriaMetrics)
3. Modifier `docker-entrypoint.sh` pour écrire aussi vers VM (en plus d'InfluxDB)
4. Laisser tourner 24-48h pour accumuler des données dans les deux systèmes
5. Valider que les données arrivent bien dans VM via vmui

### Phase 2 — Migration des données historiques (1h)

1. Utiliser `vmctl influx` pour copier les données existantes :
   ```bash
   vmctl influx \
     --influx-addr=http://influxdb:8086 \
     --influx-database=speedtest \
     --influx-user=admin --influx-password=<pass> \
     --vm-addr=http://victoriametrics:8428
   ```
2. Répéter pour la base `telegraf`
3. Valider les counts dans vmui

### Phase 3 — Migration Grafana (3-4h)

1. Créer un nouveau datasource Prometheus pointant vers VM
2. Dupliquer chaque dashboard et réécrire les queries en MetricsQL
3. Tester panel par panel en comparant avec l'original
4. Une fois validé, remplacer les dashboards originaux

**Table de traduction des queries courantes** :

| Usage          | InfluxQL                                                                                                                  | MetricsQL                                                                       |
| -------------- | ------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Download moyen | `SELECT mean("download_bandwidth") FROM "speedtest" WHERE $timeFilter GROUP BY time($__interval)`                         | `avg_over_time(speedtest_download_bandwidth{db="speedtest"}[$__interval])`      |
| CPU idle       | `SELECT mean("usage_idle") FROM "cpu" WHERE "cpu"='cpu-total' AND $timeFilter GROUP BY time($__interval)`                 | `cpu_usage_idle{cpu="cpu-total", db="telegraf"}`                                |
| RAM used %     | `SELECT mean("used_percent") FROM "mem" WHERE $timeFilter GROUP BY time($__interval)`                                     | `mem_used_percent{db="telegraf"}`                                               |
| Disk used %    | `SELECT last("used_percent") FROM "disk" WHERE "path"='/' AND $timeFilter GROUP BY time($__interval)`                     | `last_over_time(disk_used_percent{path="/", db="telegraf"}[5m])`                |
| Docker CPU     | `SELECT mean("usage_percent") FROM "docker_container_cpu" WHERE $timeFilter GROUP BY time($__interval), "container_name"` | `avg_over_time(docker_container_cpu_usage_percent{db="telegraf"}[$__interval])` |
| Network in/out | `SELECT derivative(mean("bytes_recv"), 1s) FROM "net" WHERE $timeFilter GROUP BY time($__interval), "interface"`          | `rate(net_bytes_recv{db="telegraf"}[5m])`                                       |

### Phase 4 — Migration publish-gh-pages.sh (2-3h)

Réécrire la section d'export pour utiliser l'API VictoriaMetrics :

```bash
# Exemple de nouvelle implémentation
START=$(date -d "-${DAYS} days" +%s)
END=$(date +%s)

# Export via l'API native VM (format JSON lines)
EXPORT_DATA=$(curl -sf "http://victoriametrics:8428/api/v1/export" \
    --data-urlencode 'match={__name__=~"speedtest_(download_bandwidth|upload_bandwidth|ping_latency)"}' \
    --data-urlencode "start=${START}" \
    --data-urlencode "end=${END}")

# Transformer en format data.json attendu par le frontend
JSON_DATA=$(echo "$EXPORT_DATA" | python3 scripts/vm-to-datajson.py)
```

Le script de transformation `vm-to-datajson.py` convertirait la sortie VM
vers le format `data.json` attendu par `gh-pages/app.js` et `gh-pages/lib.js`.
**Le frontend ne change pas.**

### Phase 5 — Bascule (1h)

1. Arrêter le dual-write
2. Supprimer InfluxDB et Chronograf du `docker-compose.yml`
3. Mettre à jour les scripts utilitaires (`backup.sh`, `stats.sh`)
4. Mettre à jour la simulation (`sim/`)
5. Mettre à jour les 4 pipelines de build (scripts + CI)
6. Tester la stack complète

### Phase 6 — Nettoyage (1h)

1. Supprimer les volumes Docker InfluxDB et Chronograf
2. Mettre à jour la documentation
3. Mettre à jour le README
4. Supprimer les fichiers devenus obsolètes (`sim/influxdb-init.iql`, etc.)

**Effort total estimé : 10-15h de travail**

---

## 9. Ce qu'on perd

| Fonctionnalité perdue              | Impact réel sur le projet              | Mitigation                              |
| ---------------------------------- | -------------------------------------- | --------------------------------------- |
| **InfluxQL**                       | Les queries actuelles ne marchent plus | Réécriture en MetricsQL                 |
| **Chronograf**                     | Plus d'UI admin dédiée                 | vmui intégré + Grafana                  |
| **Continuous Queries**             | Plus utilisables                       | Downsampling natif (mieux)              |
| **CLI `influx`**                   | Scripts shell à réécrire               | API HTTP `curl` (plus universel)        |
| **Multi-database retention** (OSS) | Rétention unique par défaut            | Downsampling + longue rétention         |
| **Résolution nanoseconde**         | Millisecondes uniquement               | Non-impactant (échantillonnage ≥ 20s)   |
| **Types de valeurs multiples**     | Float64 uniquement                     | Tags pour strings, pas de fields string |
| **Compatibilité Flux**             | Jamais eu (OSS 1.x)                    | Pas de régression                       |

---

## 10. Ce qu'on gagne

| Gain                               | Impact                                                                             |
| ---------------------------------- | ---------------------------------------------------------------------------------- |
| **-440 Mo de RAM**                 | Swap quasi éliminé, stabilité drastiquement améliorée                              |
| **-1 service Docker** (Chronograf) | Moins de surface d'attaque, moins de maintenance                                   |
| **Image Docker 16 Mo** (vs 300 Mo) | Déploiement plus rapide, moins de stockage                                         |
| **Sécurité maintenue**             | Releases régulières, Go à jour, patches CVE                                        |
| **Downsampling natif**             | Remplace CQ, zéro maintenance                                                      |
| **vmui intégré**                   | Pas besoin de Chronograf, accès immédiat                                           |
| **Snapshots instantanés**          | Backups plus simples et plus rapides                                               |
| **MetricsQL**                      | Langage de requête plus puissant que InfluxQL, compatible PromQL, vaste écosystème |
| **Compression 2-3×** meilleure     | Moins de stockage, moins d'I/O SD card                                             |
| **Startup 1-3s** (vs 5-15s)        | Recovery plus rapide après crash/reboot                                            |
| **Écosystème Prometheus**          | Accès à des milliers de dashboards Grafana pré-faits                               |
| **Futur-proof**                    | Communauté active, roadmap claire                                                  |

---

## 11. VictoriaMetrics vs InfluxDB 3.x — Le choix

Le document `influxdb-stack-analysis.md` mentionnait aussi InfluxDB 3.x comme
alternative (R8). Comparaison directe :

| Critère                     | VictoriaMetrics                       | InfluxDB 3.x                                  |
| --------------------------- | ------------------------------------- | --------------------------------------------- |
| **Maturité**                | Stable, production-ready depuis 2019  | Open source depuis fin 2024, encore jeune     |
| **RAM usage**               | ~50-100 Mo                            | ~150-300 Mo (Rust + DataFusion)               |
| **Compatibilité écriture**  | InfluxDB line protocol natif          | InfluxDB line protocol natif                  |
| **Compatibilité lecture**   | MetricsQL/PromQL (pas d'InfluxQL)     | **SQL + InfluxQL**                            |
| **Image Docker ARM64**      | ✅ Officielle, 16 Mo                  | ⚠️ Pas encore d'image ARM64 officielle stable |
| **Grafana integration**     | Prometheus datasource (riche, mature) | SQL datasource (nouveau)                      |
| **Communauté**              | Large, active, Slack, GitHub          | Plus petite, en croissance                    |
| **Downsampling**            | Natif (flag CLI)                      | Via SQL materialized views                    |
| **Documentation migration** | Guide dédié InfluxDB → VM + vmctl     | En cours                                      |
| **Risque projet**           | Faible (7 ans de production)          | Moyen (< 2 ans en OSS)                        |

**Verdict** : VictoriaMetrics est **le meilleur choix pour ce RPi4** car :

1. Usage RAM minimal = critique sur 4 Go
2. Image ARM64 officielle et testée
3. Migration Telegraf quasi transparente
4. vmctl pour migrer les données existantes
5. Maturité et stabilité éprouvées

InfluxDB 3.x serait intéressant pour la compatibilité InfluxQL (évite la
réécriture des queries), mais son empreinte RAM plus élevée et l'absence
d'image ARM64 stable en font un candidat moins adapté au contexte RPi4.

---

## 12. Verdict et recommandation

### Score de faisabilité

| Dimension            | Score      | Commentaire                                |
| -------------------- | ---------- | ------------------------------------------ |
| Complexité technique | ⭐⭐⭐☆☆   | Modérée — réécriture queries obligatoire   |
| Gain performance     | ⭐⭐⭐⭐⭐ | Excellent — RAM, compression, I/O          |
| Gain sécurité        | ⭐⭐⭐⭐☆  | Bon — software maintenu, CVE patchées      |
| Gain opérationnel    | ⭐⭐⭐⭐☆  | Bon — -1 service, backups simplifiés       |
| Risque de régression | ⭐⭐☆☆☆    | Faible-moyen — réécriture queries = risque |
| Effort total         | ⭐⭐⭐☆☆   | 10-15h de travail                          |

### Recommandation finale

**OUI, migrer vers VictoriaMetrics** — mais **pas en priorité immédiate**.

L'ordre recommandé reste :

| Priorité | Action                            | Coût         | Impact                                 |
| -------- | --------------------------------- | ------------ | -------------------------------------- |
| **1**    | R3 — Tuner swappiness + mem_limit | 0 € / 30 min | Stabilise sans migration               |
| **2**    | R4 — Désactiver `_internal`       | 0 € / 5 min  | -50-100 Mo RAM + I/O                   |
| **3**    | R5 — SSD USB 3.0                  | ~30 €        | Élimine le bottleneck I/O              |
| **4**    | **Migration VictoriaMetrics**     | 0 € / 10-15h | **-440 Mo RAM, sécurité, futur-proof** |

La migration VM est la recommandation #4 car les quick wins (R3, R4) et le
SSD (R5) offrent un meilleur rapport effort/gain à court terme. Mais si le
swap persiste après R3+R4, la migration VM devient **priorité #1** car c'est
la seule solution qui libère ~440 Mo de RAM sans changer de hardware.

### Conditions de déclenchement immédiat

Migrer immédiatement si l'une de ces conditions est remplie :

- Le swap reste > 30% après R3+R4
- Une CVE critique est découverte dans Go 1.18 / InfluxDB 1.8
- Un besoin de downsampling natif se fait sentir
- On prévoit d'ajouter des métriques supplémentaires (iperf3, etc.)
