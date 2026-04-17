# Recommandations logicielles (coût zéro) — Analyse de faisabilité

> **Date** : 17 avril 2026
> **Contexte** : Stack InfluxDB 1.8.10 sur Raspberry Pi 4 (4 Go RAM, SD 64 Go)
> **Document parent** : [docs/influxdb-stack-analysis.md](influxdb-stack-analysis.md)

---

## Table des matières

1. [Vue d'ensemble](#1-vue-densemble)
2. [R1 — Backup automatique par timer systemd](#2-r1--backup-automatique-par-timer-systemd)
3. [R2 — Continuous Queries pour le downsampling](#3-r2--continuous-queries-pour-le-downsampling)
4. [R3 — Tuner swappiness et limites mémoire Docker](#4-r3--tuner-swappiness-et-limites-mémoire-docker)
5. [R4 — Désactiver `_internal` ou réduire sa rétention](#5-r4--désactiver-_internal-ou-réduire-sa-rétention)
6. [Matrice de synthèse](#6-matrice-de-synthèse)
7. [Ordre d'exécution recommandé](#7-ordre-dexécution-recommandé)

---

## 1. Vue d'ensemble

Quatre recommandations de l'analyse de stack sont purement logicielles, à coût
matériel nul :

| Ref | Recommandation                     | Complexité  | Risque      | Impact                |
| --- | ---------------------------------- | ----------- | ----------- | --------------------- |
| R1  | Backup automatique (timer systemd) | Faible      | Très faible | Protection données    |
| R2  | Continuous Queries (downsampling)  | **Élevée**  | Moyen       | Perf dashboards ×5-10 |
| R3  | Tuner swappiness + mem_limit       | Faible      | Faible      | Stabilité mémoire     |
| R4  | Désactiver `_internal`             | Très faible | Très faible | Libère RAM + I/O      |

---

## 2. R1 — Backup automatique par timer systemd

### 2.1 Description

Ajouter un couple `backup.timer` / `backup.service` dans `systemd/` pour
automatiser le script `scripts/backup.sh` existant, avec rotation des anciens
backups.

### 2.2 Faisabilité

| Critère         | Évaluation                                                   |
| --------------- | ------------------------------------------------------------ |
| **Effort**      | ~1-2h de travail                                             |
| **Prérequis**   | Aucun — le script `backup.sh` fonctionne déjà                |
| **Modèle**      | Copier le pattern de `speedtest.timer` / `speedtest.service` |
| **Intégration** | Ajouter au script `install-timers.sh` existant               |

Le script `backup.sh` effectue déjà :

- Export des dashboards Grafana (via API REST)
- Export des datasources Grafana
- Backup portable InfluxDB (`influxd backup -portable`)

Il manque uniquement :

- **Rotation** : supprimer les backups de plus de N jours
- **Scheduling** : fréquence hebdomadaire recommandée (`OnCalendar=weekly`)
- **Notification** : optionnel, un log dans journald suffit

### 2.3 Implémentation type

```ini
# systemd/backup.timer
[Unit]
Description=Weekly backup InfluxDB + Grafana

[Timer]
OnCalendar=Sun *-*-* 03:00:00
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
```

```ini
# systemd/backup.service
[Service]
Type=oneshot
WorkingDirectory=%h/rpi-internet-monitoring
ExecStart=/bin/bash scripts/backup.sh
ExecStartPost=/bin/bash -c 'find %h/rpi-internet-monitoring/backups -maxdepth 1 -mtime +30 -exec rm -rf {} +'
TimeoutStartSec=600
```

### 2.4 Analyse risques / avantages / inconvénients

|                   | Détail                                                                                                                                                               |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Avantages**     | Protection contre perte de données (SD failure) ; base existante (`backup.sh`) ; pattern éprouvé (2 timers déjà en place) ; ajout dans `just install-timers` trivial |
| **Inconvénients** | Backups stockés sur la **même SD** → ne protège pas contre un crash SD ; consomme du disque (estimé ~50-100 Mo/backup)                                               |
| **Risques**       | 🟢 **Très faible** — opération read-only sur les données live, le backup InfluxDB est non-bloquant                                                                   |
| **Mitigation**    | Ajouter ultérieurement un `rsync`/`rclone` off-site (R7 du doc parent)                                                                                               |

### 2.5 Verdict

✅ **Go immédiat** — Effort minimal, zéro risque, valeur immédiate. À faire en premier.

---

## 3. R2 — Continuous Queries pour le downsampling

### 3.1 Description

Configurer des Continuous Queries (CQ) InfluxDB pour pré-agréger les données brutes
Telegraf (collectées toutes les 20s) en agrégats horaires et/ou journaliers, stockés
dans des Retention Policies dédiées. Objectif : accélérer les dashboards Grafana sur
les plages longues (30-90 jours).

### 3.2 Architecture cible

```
telegraf database:
│
├── "autogen" RP (90 jours) ← données brutes 20s (Telegraf)
│   ├── cpu, mem, disk, diskio, net, swap, system, processes, kernel,
│   │   interrupts, linux_sysctl_fs, cpu_temperature, netstat,
│   │   docker_container_cpu, docker_container_mem, docker_container_net
│   │
│   └── Volume : ~630 Mo en steady-state
│
├── "rp_1y" RP (52 semaines) ← agrégats 1h (via CQ)
│   ├── cpu, mem, disk, system, swap, net, cpu_temperature
│   │   (mêmes noms, fields aliasés pour compatibilité)
│   │
│   └── Volume estimé : ~7 Mo en steady-state
│   │   (630 Mo ÷ 90 = 7 Mo/jour brut → agrégé ×180 = ~40 Ko/jour)
│
└── "rp_infinite" RP (INF) ← agrégats journaliers (optionnel, pour trends multi-années)
    ├── cpu, mem, disk, system
    │
    └── Volume estimé : ~200 Ko/an — négligeable
```

### 3.3 Fonctionnement des CQ en InfluxDB 1.8

#### Principes clés

| Aspect            | Comportement                                                        |
| ----------------- | ------------------------------------------------------------------- |
| **Déclenchement** | Automatique, calé sur l'intervalle `GROUP BY time()`                |
| **Fenêtre**       | CQ 1h → s'exécute à chaque heure pile, traite `[H-1, H)`            |
| **Concurrence**   | CQs exécutées **séquentiellement** (pas en parallèle)               |
| **Backfill**      | ❌ **Impossible** — les CQ ne traitent que les données temps-réel   |
| **Écriture**      | Résultat écrit dans la RP/measurement cible via `SELECT INTO`       |
| **RESAMPLE**      | Option avancée pour couvrir des fenêtres plus larges (late data)    |
| **Overhead**      | Minimal — ~180 points à lire par série par heure pour un agrégat 1h |

#### Exemple de CQ

```sql
CREATE CONTINUOUS QUERY "cq_cpu_1h" ON "telegraf"
BEGIN
  SELECT mean("usage_idle") AS "usage_idle",
         mean("usage_user") AS "usage_user",
         mean("usage_system") AS "usage_system",
         mean("usage_iowait") AS "usage_iowait"
  INTO "telegraf"."rp_1y"."cpu"
  FROM "telegraf"."autogen"."cpu"
  GROUP BY time(1h), *
END
```

> **Important** : utiliser des alias explicites (`AS "usage_idle"`) pour que les
> noms de fields restent identiques entre `autogen` et `rp_1y`. Sans alias,
> `SELECT mean(*)` produit des champs préfixés `mean_usage_idle` — ce qui casse
> les requêtes Grafana existantes.

### 3.4 Le problème du backfill (données historiques)

#### Constat

Les CQ ne traitent que les nouvelles données (going forward). Les données déjà
présentes dans `autogen` ne seront **pas** rétro-agrégées. Il faut un backfill
manuel via `SELECT INTO`.

#### Évaluation du besoin actuel

| Facteur             | Valeur                              |
| ------------------- | ----------------------------------- |
| Données existantes  | ~2 jours (depuis le 15/04/2026)     |
| Volume à backfiller | ~14 Mo bruts → ~80 Ko d'agrégats    |
| Nombre de points    | ~8 640 events × 376 fields = ~3.2 M |

**Constat : le backfill est trivial aujourd'hui.** 2 jours de données, c'est une
requête unique qui prend < 5 secondes même sur le RPi4. Plus on attend, plus le
backfill sera lourd (maximum 90 jours = la rétention).

#### Stratégie de backfill

**Option A — Exécution directe sur le RPi4 (recommandé pour le volume actuel)**

```sql
-- Étape 1 : créer la RP
CREATE RETENTION POLICY "rp_1y" ON "telegraf" DURATION 52w REPLICATION 1

-- Étape 2 : backfill par measurement, 1 semaine à la fois
-- (aujourd'hui avec 2 jours de données, une seule passe suffit)
SELECT mean("usage_idle") AS "usage_idle",
       mean("usage_user") AS "usage_user",
       mean("usage_system") AS "usage_system",
       mean("usage_iowait") AS "usage_iowait"
INTO "telegraf"."rp_1y"."cpu"
FROM "telegraf"."autogen"."cpu"
WHERE time >= '2026-04-15T00:00:00Z' AND time < now()
GROUP BY time(1h), *

-- Répéter pour chaque measurement : mem, disk, diskio, net, swap, system, ...
```

**Option B — Backfill depuis un poste externe (laptop X1 Carbon)**

L'idée est séduisante mais **ne résout pas le problème** :

```
┌─────────────────────┐    query HTTP     ┌──────────────────┐
│  Laptop X1 Carbon   │ ──────────────▶   │  RPi4 — InfluxDB │
│  (client influx)    │                   │  (exécution réelle│
│                     │ ◀──────────────   │   ici, pas sur le │
│                     │    résultats      │   laptop)         │
└─────────────────────┘                   └──────────────────┘
```

Le `SELECT INTO` est une commande **serveur-side** : le laptop envoie la requête
mais c'est le processus InfluxDB sur le RPi4 qui lit, agrège et écrit. Le CPU, la
RAM et l'I/O consommés sont ceux du RPi4, pas du laptop.

**Le laptop est utile uniquement dans ces scénarios :**

| Scénario                                                         | Faisabilité    | Intérêt                                     |
| ---------------------------------------------------------------- | -------------- | ------------------------------------------- |
| Envoyer les requêtes `SELECT INTO` depuis le laptop              | ✅ Trivial     | 🟡 Aucun gain perf — exécution sur RPi      |
| Scripter le backfill (boucle par measurement × semaine)          | ✅ Confortable | 🟢 Plus facile à scripter sur un vrai shell |
| Backup → restore sur laptop → backfill local → export → reimport | ✅ Possible    | 🔴 **Overkill pour 2-90 jours de données**  |
| Monitoring du backfill (`SHOW QUERIES`, kill si nécessaire)      | ✅ Utile       | 🟢 Supervision confortable                  |

#### Vrai cas d'usage du laptop pour migration

Le laptop X1 Carbon deviendrait pertinent dans un scénario futur de **migration
vers InfluxDB 3.x** (R8) où il faudrait :

1. `influxd backup` depuis le RPi4
2. Restaurer sur le laptop
3. Exporter en line protocol / CSV
4. Transformer / re-ingérer dans InfluxDB 3.x
5. Re-déployer sur le RPi4

Pour les CQ actuelles, c'est disproportionné.

### 3.5 Stratégie de migration des dashboards Grafana

#### Impact sur les requêtes

Si les CQ utilisent des alias explicites (`AS "usage_idle"`), les noms de fields
sont **identiques** entre `autogen` et `rp_1y`. La seule différence dans les
requêtes Grafana est le nom de la RP dans le `FROM`.

| Élément    | Avant                            | Après                                      |
| ---------- | -------------------------------- | ------------------------------------------ |
| `FROM`     | `FROM "cpu"` (implicite autogen) | `FROM "rp_1y"."cpu"`                       |
| Fields     | `"usage_idle"`                   | `"usage_idle"` (identique grâce aux alias) |
| `GROUP BY` | `GROUP BY time($__interval)`     | `GROUP BY time($__interval)` (inchangé)    |
| `WHERE`    | `$timeFilter`                    | `$timeFilter` (inchangé)                   |

#### Stratégie de sélection automatique raw vs downsampled

InfluxQL ne supporte pas la sélection conditionnelle de RP. Trois approches
Grafana :

| Approche                                                                                                                                      | Complexité | UX                                          |
| --------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ------------------------------------------- |
| **A. Deux panels/lignes** séparés ("Dernières 24h" raw + "Tendances 30j+" downsampled)                                                        | Faible     | Claire, chaque panel optimisé pour sa plage |
| **B. Variable Grafana `$rp`** avec choix manuel (`autogen` / `rp_1y`)                                                                         | Faible     | Flexible mais action utilisateur requise    |
| **C. Deux queries par panel** (Query A raw `WHERE time > now()-7d` + Query B downsampled `WHERE time <= now()-7d`) avec Transform Concatenate | Moyenne    | Seamless mais plus de maintenance           |

**Recommandation : Approche A** pour commencer — c'est le plus simple, chaque
dashboard ayant déjà des plages fixes via le time picker. Les dashboards sur plages
courtes (1h-24h) restent sur `autogen`, les dashboards trends (30d-1y) pointent
sur `rp_1y`.

### 3.6 Cooldown et période de transition

#### Plan de déploiement

```
Phase 0 — Préparation (J+0, ~30 min)
├── Backup complet : just backup
├── Créer RP "rp_1y" et "rp_infinite" (optionnel)
└── Vérifier : SHOW RETENTION POLICIES ON telegraf

Phase 1 — Backfill historique (J+0, ~15-30 min)
├── Exécuter les SELECT INTO par measurement × chunk temporel
├── Vérifier les comptages : SELECT COUNT(*) FROM "rp_1y"."cpu"
└── Comparer un échantillon avec les données brutes

Phase 2 — Activation des CQ (J+0, ~30 min)
├── CREATE CONTINUOUS QUERY pour chaque measurement
├── Vérifier : SHOW CONTINUOUS QUERIES
└── Attendre 1-2h et vérifier que les agrégats arrivent

Phase 3 — Cooldown / Observation (J+0 → J+7)
├── Observer les métriques InfluxDB (_internal) :
│   - queryExecutor queries actives
│   - compaction en cours
│   - mémoire utilisée
├── Vérifier la cohérence des agrégats (spot-check)
└── Ne PAS toucher aux dashboards Grafana pendant cette phase

Phase 4 — Migration Grafana (J+7 → J+14)
├── Dupliquer les panels long-range pour pointer vers rp_1y
├── Tester côte-à-côte (raw vs downsampled)
└── Supprimer les anciens panels long-range une fois validé

Phase 5 — Validation finale (J+14 → J+21)
├── Confirmer que rp_1y se remplit correctement
├── Vérifier les temps de réponse sur 30d / 90d
└── Documenter la configuration dans docs/
```

#### Points de rollback

| Phase   | Rollback                                                                   |
| ------- | -------------------------------------------------------------------------- |
| Phase 1 | `DROP RETENTION POLICY "rp_1y" ON "telegraf"` — supprime tous les agrégats |
| Phase 2 | `DROP CONTINUOUS QUERY "cq_cpu_1h" ON "telegraf"` — arrête l'agrégation    |
| Phase 4 | Restaurer les panels Grafana depuis le backup (Phase 0)                    |

Chaque phase est **indépendamment réversible** sans perte de données brutes.

### 3.7 Liste des CQ à créer

Seules les measurements pertinentes pour des dashboards long-range méritent une CQ.
Les données comme `interrupts`, `linux_sysctl_fs`, `kernel` sont rarement consultées
sur 30+ jours.

| CQ                 | Measurement source     | Fields agrégés                                             | Priorité   |
| ------------------ | ---------------------- | ---------------------------------------------------------- | ---------- |
| `cq_cpu_1h`        | `cpu`                  | `usage_idle`, `usage_user`, `usage_system`, `usage_iowait` | 🔴 Haute   |
| `cq_mem_1h`        | `mem`                  | `used_percent`, `available_percent`, `used`, `cached`      | 🔴 Haute   |
| `cq_disk_1h`       | `disk`                 | `used_percent`, `used`, `free`                             | 🔴 Haute   |
| `cq_swap_1h`       | `swap`                 | `used_percent`, `used`, `total`                            | 🔴 Haute   |
| `cq_system_1h`     | `system`               | `load1`, `load5`, `load15`                                 | 🔴 Haute   |
| `cq_cpu_temp_1h`   | `cpu_temperature`      | `value`                                                    | 🟡 Moyenne |
| `cq_net_1h`        | `net`                  | `bytes_sent`, `bytes_recv`                                 | 🟡 Moyenne |
| `cq_diskio_1h`     | `diskio`               | `read_bytes`, `write_bytes`, `io_time`                     | 🟡 Moyenne |
| `cq_docker_cpu_1h` | `docker_container_cpu` | `usage_percent`                                            | 🟡 Moyenne |
| `cq_docker_mem_1h` | `docker_container_mem` | `usage_percent`                                            | 🟡 Moyenne |

**Pas de CQ pour** : `interrupts`, `kernel`, `linux_sysctl_fs`, `netstat`,
`processes` — données rarement consultées en long-range, overhead non justifié.

### 3.8 Analyse risques / avantages / inconvénients

|                   | Détail                                                                                                                                                                                                 |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Avantages**     | Dashboards 30-90j passent de 5-15s à < 1s ; agrégats conservés 1 an (vs 90j brut) ; vue trends longue durée ; réversible à chaque phase                                                                |
| **Inconvénients** | Complexité accrue (10 CQ à maintenir) ; chaque nouveau measurement nécessite une nouvelle CQ ; migration Grafana manuelle ; 2 sources de vérité pour les mêmes métriques                               |
| **Risques**       | 🟡 **Moyen** — un alias manquant dans une CQ produit des noms de fields incohérents ; CQ silencieusement en échec si InfluxDB manque de mémoire pendant un pic ; backfill bloquant si chunk trop large |
| **Mitigation**    | Tester chaque CQ unitairement avant activation ; monitorer `SHOW CONTINUOUS QUERIES` et `_internal` ; chunker le backfill par semaine max ; backup avant toute opération                               |

### 3.9 Estimation des ressources pour le backfill

#### Aujourd'hui (J+2, ~2 jours de données)

| Métrique               | Valeur                                       |
| ---------------------- | -------------------------------------------- |
| Points bruts à traiter | ~3.2 M fields                                |
| Temps estimé (RPi4)    | **< 30 secondes** pour tous les measurements |
| RAM pic                | ~50-100 Mo additionnels                      |
| Risque OOM             | 🟢 Nul                                       |

#### Scénario futur (J+90, 90 jours de données accumulées)

| Métrique                                 | Valeur                              |
| ---------------------------------------- | ----------------------------------- |
| Points bruts à traiter                   | ~144 M fields                       |
| Temps estimé (RPi4, chunked par semaine) | **~10-20 min** (13 chunks × ~1 min) |
| RAM pic par chunk                        | ~200-400 Mo additionnels            |
| Risque OOM                               | 🟡 Modéré si pas chunké             |

**Recommandation forte : déployer les CQ maintenant (J+2), pas dans 3 mois.**
Le backfill sera trivial maintenant, laborieux plus tard.

### 3.10 Verdict

✅ **Go avec précautions** — Impact fort (×5-10 sur les dashboards long-range) mais
complexité non négligeable. Déployer rapidement pour profiter du faible volume de
backfill. Suivre le plan de déploiement en 5 phases avec cooldown de 7 jours avant
de toucher aux dashboards Grafana.

---

## 4. R3 — Tuner swappiness et limites mémoire Docker

### 4.1 Description

Réduire l'agressivité du swap Linux (`vm.swappiness`) et ajouter des limites
mémoire (`mem_limit`) à chaque container dans `docker-compose.yml` pour éviter
les pics incontrôlés et les OOM cascades.

### 4.2 Faisabilité

| Critère           | Évaluation                                                      |
| ----------------- | --------------------------------------------------------------- |
| **Effort**        | ~30 min                                                         |
| **Prérequis**     | Accès SSH au RPi4                                               |
| **Réversibilité** | Immédiate (`sysctl` temporaire, ou revert `docker-compose.yml`) |

### 4.3 Changements proposés

#### 4.3.1 Tuning kernel — swappiness

```bash
# Vérifier la valeur actuelle
cat /proc/sys/vm/swappiness
# Probablement 60 (défaut Debian)

# Appliquer temporairement
sudo sysctl vm.swappiness=10

# Persister
echo "vm.swappiness=10" | sudo tee /etc/sysctl.d/99-swappiness.conf
```

| Valeur            | Comportement                                           |
| ----------------- | ------------------------------------------------------ |
| `60` (défaut)     | Le kernel swappe agressivement dès 40% de RAM utilisée |
| `10` (recommandé) | Le kernel ne swappe qu'en dernière nécessité           |
| `0`               | Swap uniquement pour éviter OOM kill — risqué sur 4 Go |

Valeur recommandée : **10** — bon compromis entre performance et protection OOM.

#### 4.3.2 Limites mémoire Docker (`docker-compose.yml`)

```yaml
services:
  influxdb:
    mem_limit: 1g
    memswap_limit: 1536m # 1 Go RAM + 512 Mo swap max

  grafana:
    mem_limit: 512m
    memswap_limit: 768m

  telegraf:
    mem_limit: 256m
    memswap_limit: 384m

  chronograf:
    mem_limit: 256m
    memswap_limit: 384m

  docker-socket-proxy:
    mem_limit: 64m
    memswap_limit: 64m
```

| Service             | `mem_limit` | Justification                                           |
| ------------------- | ----------- | ------------------------------------------------------- |
| InfluxDB            | 1 Go        | Cache TSM + queries, plus gros consommateur             |
| Grafana             | 512 Mo      | Rendering + alerting, pics lors de dashboards complexes |
| Telegraf            | 256 Mo      | Collecte stable, buffer 10 000 métriques max            |
| Chronograf          | 256 Mo      | UI légère, rarement sollicitée                          |
| Docker Socket Proxy | 64 Mo       | Proxy minimal, quasi-stateless                          |
| **Total alloué**    | **2 Go**    | Reste ~2 Go pour l'OS + speedtest éphémère              |

#### 4.3.3 Budget mémoire résultant

```
┌──────────────────────────────────────────────────────┐
│                    RAM 4 Go                          │
├──────────────────────────────────────────────────────┤
│  OS + kernel + systemd              │  ~500 Mo       │
│  Docker daemon                      │  ~200 Mo       │
│  InfluxDB (capped)                  │  ≤1 000 Mo     │
│  Grafana (capped)                   │  ≤  512 Mo     │
│  Telegraf (capped)                  │  ≤  256 Mo     │
│  Chronograf (capped)                │  ≤  256 Mo     │
│  Docker Socket Proxy (capped)       │  ≤   64 Mo     │
│  Speedtest éphémère (pic)           │  ~  100 Mo     │
├──────────────────────────────────────────────────────┤
│  Headroom disponible                │  ~200-500 Mo   │
│  Swap (filet de sécurité)           │  ~1-2 Go       │
└──────────────────────────────────────────────────────┘
```

### 4.4 Analyse risques / avantages / inconvénients

|                   | Détail                                                                                                                                                                                                                                                  |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Avantages**     | Réduit le swap de ~52% à ~5-15% ; dashboards Grafana plus réactifs (moins d'I/O swap sur SD) ; protection contre les OOM cascades (un container ne peut pas affamer les autres) ; usure SD réduite (moins de swap writes)                               |
| **Inconvénients** | InfluxDB pourrait être OOM-killed si une requête lourde dépasse 1 Go ; nécessite un tuning itératif (observer puis ajuster)                                                                                                                             |
| **Risques**       | 🟡 **Faible** — si `mem_limit` est trop bas, Docker kill le container → restart automatique (`restart: unless-stopped`). Les données InfluxDB survivent (WAL + TSM sur disque). Risque principal : indisponibilité temporaire (~5s le temps du restart) |
| **Mitigation**    | Commencer avec des limites conservatrices (ci-dessus), observer pendant 1 semaine, ajuster si nécessaire. Monitorer via `docker stats` ou le dashboard Docker existant                                                                                  |

### 4.5 Verdict

✅ **Go immédiat** — Risque très faible, effet immédiat sur le swap. L'observation
post-déploiement est essentielle pour ajuster les limites.

---

## 5. R4 — Désactiver `_internal` ou réduire sa rétention

### 5.1 Description

La base `_internal` d'InfluxDB collecte des métriques internes (queries/s,
compaction, WAL, cache usage, etc.) avec une rétention par défaut de 7 jours.
Elle consomme ~50-100 Mo et génère des writes continues qui sollicitent la SD
et la RAM inutilement si non consultée.

### 5.2 Options

| Option                               | Configuration                                                 | Impact                                                   |
| ------------------------------------ | ------------------------------------------------------------- | -------------------------------------------------------- |
| **A. Désactiver complètement**       | `INFLUXDB_MONITOR_STORE_ENABLED=false`                        | Économise ~50-100 Mo disque + ~10-20 Mo RAM + I/O writes |
| **B. Réduire la rétention à 1 jour** | `INFLUXDB_MONITOR_STORE_DATABASE=_internal` + modification RP | Économise ~80% du volume, garde la capacité de debug     |
| **C. Réduire à 1h**                  | Modification RP                                               | Minimal, juste pour le debug immédiat                    |

### 5.3 Implémentation

#### Option A (recommandée) — Désactiver

Ajouter dans `docker-compose.yml`, section `influxdb.environment` :

```yaml
INFLUXDB_MONITOR_STORE_ENABLED: 'false'
```

Puis `just restart-svc influxdb`. La base `_internal` ne sera plus alimentée.
Les données existantes seront expurgées par la RP expirée naturellement.

#### Option B — Rétention 1 jour

```sql
ALTER RETENTION POLICY "monitor" ON "_internal" DURATION 1d
```

### 5.4 Analyse risques / avantages / inconvénients

|                   | Détail                                                                                                                                                                                                    |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Avantages**     | ~50-100 Mo de disque récupérés ; réduction des writes sur SD (~10-15% des I/O totales d'InfluxDB) ; moins de RAM pour les shards `_internal`                                                              |
| **Inconvénients** | Perte de la capacité de diagnostic interne (combien de queries/s, état des compactions, taille du cache TSM). Si un problème de performance survient, on ne pourra pas consulter l'historique `_internal` |
| **Risques**       | 🟢 **Très faible** — `_internal` est optionnel, son absence n'affecte pas le fonctionnement normal. Réversible en supprimant la variable d'environnement                                                  |
| **Mitigation**    | Option B (rétention 1 jour) offre un compromis si le diagnostic est nécessaire. Alternative : monitorer InfluxDB via `docker stats` + le dashboard Docker existant dans Grafana                           |

### 5.5 Recommandation

Pour un RPi4 avec ressources limitées, **l'option A (désactiver)** est préférable.
Les métriques de diagnostic InfluxDB sont accessibles ponctuellement via
`SHOW DIAGNOSTICS` et `SHOW STATS` (ne nécessitent pas `_internal`).

Si un doute subsiste, commencer par l'**option B (rétention 1 jour)** pendant
1 mois, puis passer à l'option A si `_internal` n'a pas été consultée.

### 5.6 Verdict

✅ **Go immédiat** — Changement d'une ligne, effet mesurable, zéro risque
fonctionnel.

---

## 6. Matrice de synthèse

| Critère            |  R1 Backup auto  |            R2 Cont. Queries             | R3 Swappiness |   R4 `_internal`    |
| ------------------ | :--------------: | :-------------------------------------: | :-----------: | :-----------------: |
| **Effort**         |       1-2h       |           4-8h (+7j cooldown)           |    30 min     |        5 min        |
| **Complexité**     |      Faible      |                 Élevée                  |    Faible     |     Très faible     |
| **Risque**         |  🟢 Très faible  |                🟡 Moyen                 |   🟡 Faible   |   🟢 Très faible    |
| **Réversibilité**  |    Immédiate     |          Immédiate (par phase)          |   Immédiate   |      Immédiate      |
| **Impact perf**    |      Aucun       |          **×5-10 dashboards**           |   Swap -40%   | RAM +20Mo, I/O -15% |
| **Impact données** | Protection perte |             Historique 1an              |     Aucun     |  Perte diagnostic   |
| **Dépendance**     |      Aucune      |                 Aucune                  |    Aucune     |       Aucune        |
| **Besoin laptop**  |       Non        |       Non (utile pour scripting)        |      Non      |         Non         |
| **Urgence**        |      Haute       | **Haute** (backfill trivial maintenant) |     Haute     |        Basse        |

---

## 7. Ordre d'exécution recommandé

```
Semaine 1 — Quick wins
├── Jour 1
│   ├── R4 : Désactiver _internal (5 min)
│   ├── R3 : Tuner swappiness=10 (10 min)
│   ├── R3 : Ajouter mem_limit dans docker-compose.yml (20 min)
│   └── Observer : docker stats, just status, swap usage
│
├── Jour 2-3
│   ├── R1 : Créer backup.timer + backup.service (1h)
│   ├── R1 : Ajouter rotation dans le service (15 min)
│   ├── R1 : Intégrer dans install-timers.sh (15 min)
│   └── Tester : just install-timers && systemctl --user list-timers
│
├── Jour 3-4 — R2 Phase 0+1+2
│   ├── just backup (sauvegarde avant migration)
│   ├── Créer les Retention Policies (rp_1y, optionnel rp_infinite)
│   ├── Backfill historique (~2 jours de données, < 30s)
│   ├── Créer les 10 Continuous Queries
│   └── Vérifier : SHOW CONTINUOUS QUERIES
│
└── Jour 4-7 — R2 Phase 3 (cooldown)
    ├── Observer les CQ (agrégats correctement produits ?)
    ├── Spot-check : comparer agrégats vs moyennes manuelles
    └── Surveiller RAM/swap/I/O

Semaine 2 — Migration Grafana (R2 Phase 4)
├── Dupliquer les panels long-range → pointer vers rp_1y
├── Tester côte-à-côte
└── Valider temps de réponse sur 30j / 90j

Semaine 3 — Validation finale (R2 Phase 5)
├── Confirmer que tout fonctionne depuis 2 semaines
├── Supprimer les anciens panels long-range
├── Ajuster les mem_limit si nécessaire (données R3)
└── Documenter la configuration finale
```

**Temps total estimé** : ~6-10h de travail réparti sur 3 semaines (dont 2 semaines
d'observation passive).
