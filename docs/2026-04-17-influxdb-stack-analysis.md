# Analyse complète de la stack — Focus InfluxDB

> **Date** : 17 avril 2026
> **Hardware** : Raspberry Pi 4 Model B — 4 Go RAM — SD 64 Go
> **Stack** : Docker Compose (6 services)
> **Données live** : https://yoyonel.github.io/rpi-internet-monitoring/

---

## Table des matières

1. [Inventaire des services](#1-inventaire-des-services)
2. [InfluxDB 1.8.10 — État et analyse](#2-influxdb-1810--état-et-analyse)
3. [Volumétrie des données](#3-volumétrie-des-données)
4. [Projection de l'évolution dans le temps](#4-projection-de-lévolution-dans-le-temps)
5. [Performance des requêtes](#5-performance-des-requêtes)
6. [Risques et limites](#6-risques-et-limites)
7. [Recommandations et feuille de route](#7-recommandations-et-feuille-de-route)

---

## 1. Inventaire des services

| Service             | Image                               | Version                             | Rôle                       |
| ------------------- | ----------------------------------- | ----------------------------------- | -------------------------- |
| **InfluxDB**        | `influxdb:1.8.10`                   | **1.8.10** (dernière 1.x, Oct 2022) | Time-series DB             |
| Grafana             | `grafana/grafana:12.4.3`            | 12.4.3                              | Dashboards + Alerting      |
| Telegraf            | `telegraf:1.38.2`                   | 1.38.2                              | Collecte métriques système |
| Chronograf          | `chronograf:1.9.4`                  | 1.9.4                               | Admin UI InfluxDB          |
| Speedtest           | `speedtest:bookworm`                | custom build (Debian Bookworm)      | Test débit Ookla           |
| Docker Socket Proxy | `tecnativa/docker-socket-proxy:0.3` | 0.3                                 | Accès Docker restreint     |

### Architecture

```
┌────────────┐  */10 min  ┌───────────┐   write    ┌──────────┐
│  systemd   │───────────▶│ speedtest │───────────▶│ InfluxDB │
│  timer     │            └───────────┘            │  1.8.10  │
└────────────┘                                     └────┬─────┘
┌──────────┐   collect   ┌───────────┐   write         │
│  System  │────────────▶│ Telegraf  │─────────────────▶│
│  metrics │  (20s)      │  1.38.2   │                  │
└──────────┘             └───────────┘                  │
                                                        │
                         ┌───────────┐   query          │
                         │  Grafana  │◀─────────────────┘
                         │  12.4.3   │
                         └───────────┘
                         ┌────────────┐  query
                         │ Chronograf │◀────────────────┘
                         │   1.9.4    │
                         └────────────┘
```

---

## 2. InfluxDB 1.8.10 — État et analyse

### 2.1 Moteur et architecture

| Caractéristique  | Valeur                                                        |
| ---------------- | ------------------------------------------------------------- |
| Moteur stockage  | **TSM** (Time-Structured Merge Tree)                          |
| Langage requêtes | **InfluxQL** uniquement (pas de Flux en OSS 1.x)              |
| API              | HTTP REST sur port 8086 (exposé uniquement en interne Docker) |
| Auth             | Basic auth (username/password via env vars)                   |
| Mode             | **Single-node** (pas de clustering en OSS)                    |
| Compaction       | Background merges automatiques des TSM files                  |

### 2.2 Bases de données

| Base        | Rétention        | Contenu                                               | Fréquence écriture                                       |
| ----------- | ---------------- | ----------------------------------------------------- | -------------------------------------------------------- |
| `speedtest` | **∞ (infinie)**  | download, upload, ping (3 fields + 1 tag)             | **144 points/jour** (1 point / 10 min)                   |
| `telegraf`  | **90 jours**     | CPU, RAM, disk, net, docker, temp… (~15 measurements) | **4 320 events/jour** (1 event / 20s, ~376 fields/event) |
| `_internal` | 7 jours (défaut) | Métriques internes InfluxDB                           | Auto-généré                                              |

### 2.3 Configuration notable

```yaml
INFLUXDB_DATA_MAX_VALUES_PER_TAG: 0 # Pas de limite tag cardinality
INFLUXDB_HTTP_AUTH_ENABLED: 'true' # Auth activée
```

Pas de tuning custom du TSM engine (cache size, compaction thresholds, etc.)
→ valeurs par défaut InfluxDB 1.8.

### 2.4 Cycle de vie InfluxDB 1.x

| Aspect               | État                                                       |
| -------------------- | ---------------------------------------------------------- |
| Dernière release 1.x | **1.8.10** (Oct 2022) — c'est la version utilisée          |
| Statut               | **Maintenance mode / EOL** — aucune release depuis 2.5 ans |
| Patches sécurité     | Plus garantis                                              |
| Successeur officiel  | InfluxDB 3.x (Open Source depuis fin 2024)                 |
| Go version embarquée | Go 1.18.x (CVE connues non patchées)                       |

**Risque** : pas de corrections de bugs ni de failles de sécurité. La version Go
embarquée (1.18) a des vulnérabilités connues. Le port 8086 n'étant exposé qu'en
interne Docker (`expose` et non `ports`), le risque réseau est atténué.

---

## 3. Volumétrie des données

### 3.1 Données observées (site live au 17/04/2026)

| Métrique           | Valeur                                            |
| ------------------ | ------------------------------------------------- |
| Plage affichée     | 15/04 11:00 → 17/04 11:00 (~2 jours)              |
| Points speedtest   | **288 pts** → confirme 144 pts/jour               |
| Médiane download   | 941 Mb/s                                          |
| Médiane upload     | 681 Mb/s                                          |
| Médiane ping       | 11.6 ms                                           |
| Démarrage stack v2 | **15 avril 2026** (premier commit le 15/04 22:26) |

> Note : le projet d'origine remonte à novembre 2022 (traces dans le fichier
> historique `2022-11-23 - RPI Debian GNU-Linux 11 (bullseye).md`), mais les données
> actuelles ne remontent qu'au 15/04/2026 (refonte v2 de la stack).

### 3.2 Estimation volumétrique par base

#### Base `speedtest` (rétention infinie)

| Métrique                    | Valeur                                                       |
| --------------------------- | ------------------------------------------------------------ |
| Points/jour                 | 144                                                          |
| Fields/point                | 3 (`download_bandwidth`, `upload_bandwidth`, `ping_latency`) |
| Tags/point                  | 1 (`result_id`)                                              |
| Taille compressée TSM/point | ~20-25 octets                                                |
| **Volume/jour**             | **~3.5 Ko**                                                  |
| **Volume/mois**             | **~105 Ko**                                                  |
| **Volume/an**               | **~1.3 Mo**                                                  |

#### Base `telegraf` (rétention 90 jours)

Telegraf collecte **15 mesures** toutes les 20 secondes :

| Measurement                           | Séries         | Fields estimés              |
| ------------------------------------- | -------------- | --------------------------- |
| `cpu` (per-core + total)              | 5              | ~50                         |
| `mem`                                 | 1              | ~20                         |
| `disk` (2-3 partitions)               | 3              | ~45                         |
| `diskio` (2-3 devices)                | 3              | ~30                         |
| `net` (eth0, wlan0)                   | 2              | ~30                         |
| `netstat`                             | 1              | ~10                         |
| `swap`                                | 1              | ~5                          |
| `system`                              | 1              | ~5                          |
| `processes`                           | 1              | ~10                         |
| `kernel`                              | 1              | ~5                          |
| `interrupts`                          | ~20            | ~60                         |
| `linux_sysctl_fs`                     | 1              | ~5                          |
| `cpu_temperature`                     | 1              | ~1                          |
| `docker_container_*` (5-6 containers) | ~30            | ~100                        |
| **Total**                             | **~71 séries** | **~376 field values/event** |

| Métrique                             | Calcul                            | Valeur           |
| ------------------------------------ | --------------------------------- | ---------------- |
| Events/jour                          | 86 400 s ÷ 20 s                   | 4 320            |
| Field writes/jour                    | 4 320 × 376                       | **~1.6 M**       |
| Taille compressée/field              | ~2-3 octets (TSM delta + Gorilla) | —                |
| **Volume brut/jour**                 | 1.6M × 2.5 octets                 | **~4 Mo**        |
| Overhead TSM (index, WAL, bloom)     | ×1.5-2                            | **~6-8 Mo/jour** |
| **Volume à 90 jours (steady-state)** | 7 Mo × 90                         | **~630 Mo**      |

#### Base `_internal`

| Métrique                     | Valeur           |
| ---------------------------- | ---------------- |
| Rétention                    | 7 jours (défaut) |
| Volume estimé (steady-state) | **~50-100 Mo**   |

### 3.3 Volume total InfluxDB

| Composant   | Volume (actuel, J+2) |
| ----------- | -------------------- |
| `speedtest` | ~7 Ko                |
| `telegraf`  | ~14 Mo               |
| `_internal` | ~20 Mo               |
| **Total**   | **~35 Mo**           |

---

## 4. Projection de l'évolution dans le temps

### 4.1 Courbe de croissance du volume disque InfluxDB

Le facteur clé : **`telegraf` est capé à 90 jours de rétention**,
donc la courbe se stabilise après 3 mois.

| Horizon              | `speedtest` | `telegraf` | `_internal` | **Total InfluxDB** |
| -------------------- | ----------- | ---------- | ----------- | ------------------ |
| **J+2** (maintenant) | 7 Ko        | 14 Mo      | 20 Mo       | **~35 Mo**         |
| **J+30** (1 mois)    | 105 Ko      | 210 Mo     | 70 Mo       | **~280 Mo**        |
| **J+90** (3 mois)    | 315 Ko      | 630 Mo     | 100 Mo      | **~730 Mo**        |
| **J+365** (1 an)     | 1.3 Mo      | 630 Mo     | 100 Mo      | **~730 Mo**        |
| **J+1095** (3 ans)   | 3.8 Mo      | 630 Mo     | 100 Mo      | **~734 Mo**        |
| **J+1825** (5 ans)   | 6.4 Mo      | 630 Mo     | 100 Mo      | **~736 Mo**        |

```
Volume (Mo)
  800 ┤
      │                          ┌──────────────────────────
  700 ┤                      ╱───┘   ← steady-state ~730 Mo
      │                  ╱───┘         (telegraf rétention 90j)
  600 ┤              ╱───┘
      │          ╱───┘
  500 ┤      ╱───┘
      │  ╱───┘
  400 ┤╱──┘
      │──┘
  300 ┤──┘
      │─┘
  200 ┤┘
      │
  100 ┤
      │
    0 ┼──────┬──────┬──────┬──────┬──────┬──────┬──────────▶
      J+0   J+15  J+30   J+45  J+60   J+75  J+90        temps
```

**Le volume est essentiellement stable après 90 jours.** La croissance annuelle
au-delà est de ~1.3 Mo/an (speedtest uniquement) — négligeable.

### 4.2 Budget disque global sur la SD 64 Go

| Composant                      | Volume estimé          |
| ------------------------------ | ---------------------- |
| OS Raspberry Pi (Bookworm)     | ~4-5 Go                |
| Docker engine + metadata       | ~1 Go                  |
| Images Docker (6 images ARM64) | ~1.5-2 Go              |
| InfluxDB data (steady-state)   | ~0.7-1 Go              |
| Grafana storage                | ~200-500 Mo            |
| Chronograf data                | ~50-100 Mo             |
| Logs système + journald        | ~200-500 Mo            |
| Swap file                      | ~1-2 Go                |
| **Total estimé**               | **~9-12 Go**           |
| **Espace libre projeté**       | **~52-55 Go (81-86%)** |

Les alertes live indiquent un disk usage à 42% (26.9 Go utilisés) — l'écart avec
l'estimation suggère la présence de données historiques, backups, ou fichiers
utilisateur additionnels sur la SD.

**Verdict : la capacité disque de 64 Go est largement suffisante, même à horizon 5+ ans.**

### 4.3 Pression mémoire (RAM 4 Go)

| Processus                               | RAM estimée     |
| --------------------------------------- | --------------- |
| OS + kernel + systemd                   | ~400-600 Mo     |
| Docker daemon                           | ~150-250 Mo     |
| InfluxDB (TSM cache + queries)          | **300-500 Mo**  |
| Grafana                                 | 200-400 Mo      |
| Telegraf                                | 100-200 Mo      |
| Chronograf                              | 80-150 Mo       |
| Docker-socket-proxy                     | ~20 Mo          |
| Speedtest (éphémère, toutes les 10 min) | ~100 Mo (pic)   |
| **Total en usage normal**               | **~1.5-2.2 Go** |
| **Pic (speedtest + Grafana query)**     | **~2.5-3 Go**   |

Les alertes live confirment : **RAM à 25%, Swap à 52%** (alerting en `FIRING`).
Le swap actif indique que les pics dépassent ponctuellement la mémoire physique
(ou que la valeur `swappiness` du kernel est élevée). C'est le **bottleneck principal**.

---

## 5. Performance des requêtes

### 5.1 Facteurs de performance sur RPi4

| Facteur           | Valeur                                | Impact                                 |
| ----------------- | ------------------------------------- | -------------------------------------- |
| CPU               | ARM Cortex-A72 @ 1.5 GHz, 4 cores     | Modéré — InfluxQL utilise 1 core/query |
| RAM               | 4 Go (dispo ~1-2 Go pour InfluxDB)    | Cache TSM limité                       |
| **I/O (SD card)** | ~30-50 Mo/s séq, **~2-5 Mo/s random** | **Bottleneck principal**               |
| Réseau            | Localhost (Docker bridge)             | Négligeable                            |

La carte SD est le facteur limitant principal. Un SSD affiche ~0.05 ms de latence
random vs ~1-5 ms pour une SD → **20-100× plus lent sur les accès aléatoires**.

### 5.2 Base `speedtest` — Temps de réponse estimés

Requête type :

```sql
SELECT download_bandwidth, upload_bandwidth, ping_latency
FROM speedtest WHERE time > now() - <range>
```

| Plage       | Points scannés | TSM blocks | **Temps estimé** |
| ----------- | -------------- | ---------- | ---------------- |
| **1 jour**  | 144            | 1          | **< 10 ms**      |
| **7 jours** | 1 008          | 1-2        | **10-20 ms**     |
| **1 mois**  | 4 320          | 1-2        | **20-50 ms**     |
| **3 mois**  | 12 960         | 2-4        | **50-100 ms**    |
| **1 an**    | 52 560         | 5-10       | **100-300 ms**   |
| **3 ans**   | 157 680        | 15-30      | **300-800 ms**   |

**Les requêtes speedtest restent fluides même à 3 ans d'historique.**

### 5.3 Base `telegraf` — Temps de réponse estimés

#### Requête simple (1 measurement)

```sql
SELECT mean(usage_idle) FROM cpu
WHERE cpu='cpu-total' AND time > now() - <range>
GROUP BY time(1m)
```

| Plage                      | Points bruts | Points agrégés | TSM blocks | **Temps estimé** |
| -------------------------- | ------------ | -------------- | ---------- | ---------------- |
| **1 jour**                 | 4 320        | 1 440          | 1-2        | **50-100 ms**    |
| **7 jours**                | 30 240       | 10 080         | 3-5        | **100-300 ms**   |
| **1 mois**                 | 129 600      | 43 200         | 10-15      | **300-800 ms**   |
| **3 mois** (max rétention) | 388 800      | 129 600        | 30-40      | **1-3 s**        |

#### Requête dashboard complète (10+ séries, multi-measurement)

Grafana charge typiquement 5-10 panels, chacun avec 1-3 queries → 10-30 queries
parallèles.

| Plage            | Points totaux scannés | **Temps estimé (Grafana full load)** |
| ---------------- | --------------------- | ------------------------------------ |
| **1 jour**       | ~50 000               | **200 ms – 500 ms**                  |
| **7 jours**      | ~350 000              | **500 ms – 1.5 s**                   |
| **1 mois**       | ~1.5 M                | **2-5 s**                            |
| **3 mois** (max) | ~4.5 M                | **5-15 s**                           |

#### Requête lourde (toutes séries, sans agrégation)

```sql
SELECT * FROM cpu WHERE time > now() - 90d
```

→ ~1.9 M points

| Scénario               | **Temps estimé**                                |
| ---------------------- | ----------------------------------------------- |
| Sans GROUP BY          | **10-30 s** (+ risque OOM si résultat > 500 Mo) |
| Avec GROUP BY time(5m) | **3-8 s**                                       |
| Avec GROUP BY time(1h) | **1-3 s**                                       |

### 5.4 Synthèse performance

```
                Speedtest DB                    Telegraf DB (dashboard complet)
   ┌────────────────────────────┐    ┌────────────────────────────────────────┐
   │ 1j     ██  <10ms           │    │ 1j     ████  200-500ms                │
   │ 7j     ██  10-20ms         │    │ 7j     ██████  500ms-1.5s             │
   │ 1m     ███  20-50ms        │    │ 1m     █████████  2-5s                │
   │ 3m     ████  50-100ms      │    │ 3m     █████████████  5-15s           │
   │ 1an    ██████  100-300ms   │    │        (rétention 90j max)            │
   │ 3ans   ████████  300-800ms │    │                                       │
   └────────────────────────────┘    └───────────────────────────────────────┘
```

---

## 6. Risques et limites

### 6.1 Risques critiques

| #   | Risque                                                                  | Sévérité | Impact                              |
| --- | ----------------------------------------------------------------------- | -------- | ----------------------------------- |
| 1   | **InfluxDB 1.8.10 EOL** — pas de patches sécurité depuis Oct 2022       | 🔴 Élevé | Vulnérabilités Go 1.18 non patchées |
| 2   | **Swap à 52%** — pression mémoire, 4 Go partagés entre 6 containers     | 🟡 Moyen | Dégradation perf, risque OOM kill   |
| 3   | **Usure carte SD** — writes continues (Telegraf 20s + WAL + compaction) | 🟡 Moyen | Failure SD sous 2-4 ans             |

### 6.2 Limites structurelles

| Limite                        | Détail                                                           |
| ----------------------------- | ---------------------------------------------------------------- |
| **Pas de Flux**               | InfluxQL seul en OSS 1.x — transformations complexes impossibles |
| **Pas de downsampling**       | Pas de Continuous Queries → données brutes uniquement            |
| **Single-node**               | Pas de HA, perte de données si SD défaillante                    |
| **Pas de backup automatique** | `just backup` est manuel — aucun timer systemd pour backup       |

### 6.3 Points positifs

- Cardinalité faible (~71 séries) → très loin du plafond InfluxDB 1.x (~1M)
- Volume de données stable grâce à la rétention 90j sur telegraf
- Le disque ne sera jamais un problème (< 1 Go sur 64 Go)
- Requêtes speedtest quasi-instantanées quelle que soit la plage
- Sécurité réseau correcte : InfluxDB non exposé hors Docker network
- Credentials passés via process substitution (pas dans `/proc/cmdline`)

---

## 7. Recommandations et feuille de route

### 7.1 Court terme (0-3 mois) — Quick wins, coût minimal

#### R1. Ajouter un backup automatique par timer systemd

**Coût : 0 €** — Travail uniquement.

Créer un timer `backup.timer` + `backup.service` similaires aux timers existants,
avec une fréquence quotidienne ou hebdomadaire, et rotation des backups (garder
les N derniers). Un `rsync` vers un NAS ou un stockage cloud (rclone → Google Drive,
S3, etc.) sécuriserait les données off-site.

#### R2. Ajouter des Continuous Queries pour le downsampling

**Coût : 0 €**

Configurer des CQ InfluxDB pour pré-agréger les données telegraf par heure et par
jour → accélérer les requêtes Grafana sur les plages longues (30-90 jours) :

```sql
CREATE CONTINUOUS QUERY "cq_cpu_1h" ON "telegraf"
BEGIN
  SELECT mean("usage_idle") AS "usage_idle"
  INTO "telegraf"."autogen"."cpu_1h"
  FROM "cpu" WHERE "cpu" = 'cpu-total'
  GROUP BY time(1h)
END
```

Gain attendu : dashboards 90j passent de **5-15s** à **< 1s**.

#### R3. Tuner le swappiness et les limites mémoire Docker

**Coût : 0 €**

- `vm.swappiness=10` (au lieu de 60 par défaut) pour réduire le swap
- Ajouter des `mem_limit` dans `docker-compose.yml` pour éviter les OOM cascades :
  - InfluxDB : `mem_limit: 1g`
  - Grafana : `mem_limit: 512m`
  - Telegraf : `mem_limit: 256m`
  - Chronograf : `mem_limit: 256m`

#### R4. Désactiver `_internal` ou réduire sa rétention

**Coût : 0 €**

La base `_internal` consomme ~50-100 Mo pour des métriques rarement consultées.
La désactiver (`INFLUXDB_MONITOR_STORE_ENABLED=false`) ou réduire sa rétention à
1 jour libérerait de la RAM et de l'I/O.

---

### 7.2 Moyen terme (3-12 mois) — Améliorations matérielles ciblées

#### R5. Remplacer la carte SD par un SSD USB 3.0

**Coût : 25-50 €**

C'est **la recommandation la plus impactante**. Le RPi4 supporte le boot USB natif
(depuis le firmware de Sept 2020).

| Composant                                   | Exemples                     | Prix indicatif |
| ------------------------------------------- | ---------------------------- | -------------- |
| SSD SATA 2.5" 120-256 Go                    | Kingston A400, Crucial BX500 | 15-25 €        |
| Boîtier USB 3.0 → SATA                      | Sabrent, Ugreen              | 8-12 €         |
| **Alternative : SSD NVMe M.2 + adaptateur** | WD SN580 + Argon ONE M.2     | 30-50 €        |

**Gains attendus :**

| Métrique              | SD card                   | SSD               |
| --------------------- | ------------------------- | ----------------- |
| Lecture séquentielle  | 30-50 Mo/s                | 300-400 Mo/s      |
| Écriture séquentielle | 15-25 Mo/s                | 200-400 Mo/s      |
| IOPS random 4K        | 500-2 000                 | **20 000-80 000** |
| Latence random        | 1-5 ms                    | 0.05-0.1 ms       |
| Durée de vie          | 2-4 ans (writes intenses) | **10+ ans**       |
| Requête Telegraf 90j  | 5-15 s                    | **0.5-2 s**       |

**ROI** : Pour ~30 €, on élimine le bottleneck I/O, on réduit les temps de réponse
de 5-10×, et on supprime le risque d'usure SD. C'est le meilleur rapport coût/bénéfice.

#### R6. Augmenter la RAM — Envisager un RPi 4 8 Go ou RPi 5

Si le swap reste problématique même après tuning (R3), l'upgrade RAM est l'option suivante.

| Option             | RAM   | CPU                    | Prix indicatif |
| ------------------ | ----- | ---------------------- | -------------- |
| RPi 4 Model B 8 Go | 8 Go  | Cortex-A72 1.5 GHz     | ~75-85 €       |
| **RPi 5 8 Go**     | 8 Go  | **Cortex-A76 2.4 GHz** | **~90-100 €**  |
| RPi 5 16 Go        | 16 Go | Cortex-A76 2.4 GHz     | ~120-130 €     |

Note : il n'est pas possible d'ajouter de la RAM à un RPi existant. L'upgrade
nécessite un nouveau board.

#### R7. Ajouter un timer de backup off-site automatisé

**Coût : 0-5 €/mois**

Après R1 (backup local), ajouter un sync automatique vers le cloud :

| Solution                          | Coût                            | Capacité  |
| --------------------------------- | ------------------------------- | --------- |
| `rclone` → Google Drive (gratuit) | 0 €                             | 15 Go     |
| `rclone` → Backblaze B2           | ~0.005 €/Go/mois → ~0.05 €/mois | Illimité  |
| `rsync` → NAS local (si existant) | 0 €                             | Selon NAS |

---

### 7.3 Long terme (12-24 mois) — Évolution de la stack

#### R8. Migrer InfluxDB 1.8 → InfluxDB 3.x

**Coût : 0 € (software) + temps de migration**

InfluxDB 3.x (Open Source Core, Apache 2.0 depuis fin 2024) apporte :

| Feature           | InfluxDB 1.8     | InfluxDB 3.x                                 |
| ----------------- | ---------------- | -------------------------------------------- |
| Moteur stockage   | TSM (Go)         | **Apache DataFusion + Parquet** (Rust)       |
| Langage requêtes  | InfluxQL         | **SQL + InfluxQL**                           |
| Performance       | Correcte         | **3-10× plus rapide** (benchmarks officiels) |
| Compression       | ~2-3 bytes/field | **~0.5-1 byte/field** (Parquet columnar)     |
| RAM usage         | ~300-500 Mo      | ~150-300 Mo (Rust, pas de GC)                |
| Sécurité          | EOL, Go 1.18     | Maintenu, Rust (memory-safe)                 |
| API compatibilité | —                | Compatible InfluxDB 1.x line protocol        |

**Risques de migration :**

- Les dashboards Grafana avec requêtes InfluxQL devront être adaptés (ou utiliser le mode InfluxQL compat de 3.x)
- Chronograf ne fonctionnera plus (remplacé par l'UI intégrée de 3.x ou la CLI `influxdb3`)
- `docker-entrypoint.sh` devra adapter l'écriture (le line protocol reste compatible)
- Les Continuous Queries devront être migrées vers des mécanismes natifs 3.x

**Note** : la migration n'est pas urgente tant que le port 8086 reste strictement
interne au réseau Docker. Le risque sécurité est contenu. Priorité : SSD (R5) d'abord.

#### R9. Évaluer le remplacement par un RPi 5 + NVMe natif

**Coût : 100-160 €** (board + boîtier NVMe + SSD)

Le Raspberry Pi 5 offre un slot PCIe natif (via HAT M.2) qui élimine le goulot
USB 3.0 et apporte un CPU 60% plus rapide :

| Composant                                        | Prix indicatif |
| ------------------------------------------------ | -------------- |
| RPi 5 8 Go                                       | 90-100 €       |
| Official RPi M.2 HAT+                            | 12-15 €        |
| SSD NVMe M.2 2230/2242 256 Go                    | 25-35 €        |
| Boîtier compatible (Argon ONE V3, Pimoroni NVMe) | 15-25 €        |
| Alimentation USB-C 5V/5A officielle              | 12-15 €        |
| **Total**                                        | **~155-190 €** |

**Gains** : CPU +60%, I/O NVMe native (1500+ Mo/s séq), RAM 8 Go.
Les requêtes Telegraf 90j passeraient de 5-15s à **< 500ms**.

#### R10. Considérer Victoria Metrics comme alternative

Si la migration InfluxDB 3.x s'avère complexe, **VictoriaMetrics** est une
alternative drop-in plus légère :

| Aspect        | InfluxDB 1.8  | VictoriaMetrics                                     |
| ------------- | ------------- | --------------------------------------------------- |
| RAM usage     | 300-500 Mo    | **50-150 Mo**                                       |
| Compression   | ~2-3 bytes/pt | **~0.5-1 byte/pt**                                  |
| Compatibilité | Native        | Compatible InfluxDB line protocol + InfluxQL        |
| Maintenance   | EOL           | Activement maintenu                                 |
| Migration     | —             | Quasi drop-in (changement d'URL dans telegraf.conf) |

---

### 7.4 Synthèse des coûts et priorités

| Priorité | Recommandation                    | Horizon     | Coût            | Impact                             |
| -------- | --------------------------------- | ----------- | --------------- | ---------------------------------- |
| **1**    | R3 — Tuner swappiness + mem_limit | Court terme | **0 €**         | 🟢 Réduit swap, stabilise la stack |
| **2**    | R1 — Backup automatique (timer)   | Court terme | **0 €**         | 🟢 Protection données              |
| **3**    | R4 — Désactiver `_internal`       | Court terme | **0 €**         | 🟢 Libère RAM + I/O                |
| **4**    | R2 — Continuous Queries           | Court terme | **0 €**         | 🟢 Dashboards 5-10× plus rapides   |
| **5**    | **R5 — SSD USB 3.0**              | Moyen terme | **~30 €**       | 🟢🟢🟢 **Meilleur ROI**            |
| 6        | R7 — Backup off-site cloud        | Moyen terme | **0-1 €/mois**  | 🟢 Disaster recovery               |
| 7        | R8 — Migration InfluxDB 3.x       | Long terme  | **0 €** + temps | 🟡 Sécurité + perf                 |
| 8        | R9 — RPi 5 + NVMe                 | Long terme  | **~160 €**      | 🟡 Upgrade complète                |
| 9        | R6 — RPi 8 Go RAM                 | Moyen-long  | **~80-100 €**   | 🟡 Seulement si swap persiste      |
| 10       | R10 — VictoriaMetrics             | Long terme  | **0 €** + temps | 🟡 Alternative à R8                |

### 7.5 Budget total estimé

| Scénario                                       | Investissement      | Résultat                                     |
| ---------------------------------------------- | ------------------- | -------------------------------------------- |
| **Minimal** (R1-R4 software only)              | **0 €**             | Stack stabilisée, backup, dashboards rapides |
| **Recommandé** (R1-R5 + SSD)                   | **~30 €**           | Bottleneck I/O éliminé, durée de vie ×5      |
| **Confortable** (R1-R7 + SSD + backup cloud)   | **~35 € + 1€/mois** | Stack robuste, données protégées             |
| **Full upgrade** (RPi 5 + NVMe + migration DB) | **~160 €**          | Stack modernisée, performances ×10           |
