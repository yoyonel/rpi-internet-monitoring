# Monitoring Débit Internet — RPi4

Stack Docker pour monitorer le débit internet (download, upload, ping) via [Ookla Speedtest CLI](https://www.speedtest.net/apps/cli), avec stockage dans InfluxDB et visualisation dans Grafana.

## Architecture

```
┌────────────┐  */10 min  ┌───────────┐   write    ┌──────────┐
│  systemd   │───────────▶│ speedtest │───────────▶│ InfluxDB │
│  timer     │            └───────────┘            │  1.8.10  │
└────────────┘                                     └────┬─────┘
┌──────────┐   collect   ┌───────────┐   write         │
│  System  │────────────▶│ Telegraf  │─────────────────▶│
│  metrics │             │  1.38.2   │                  │
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

┌────────────┐  */10 min  ┌──────────────┐  push   ┌──────────────┐
│  systemd   │───────────▶│ publish      │────────▶│ GitHub Pages │
│  timer     │            │ (InfluxDB →  │         │ (static HTML │
└────────────┘            │  Chart.js)   │         │  + Chart.js) │
                          └──────────────┘         └──────────────┘
```

## Services

| Service    | Version  | Port           | Description                                        |
| ---------- | -------- | -------------- | -------------------------------------------------- |
| Grafana    | 12.4.3   | 3000           | Dashboards (SpeedTest, System, Docker, RPi Alerts) |
| InfluxDB   | 1.8.10   | 8086 (interne) | Time-series DB                                     |
| Chronograf | 1.9.4    | 8888           | Admin InfluxDB                                     |
| Telegraf   | 1.38.2   | —              | Métriques système (CPU, RAM, disk, temp)           |
| Speedtest  | bookworm | —              | Test débit Ookla, toutes les 10 min                |

## Quick Start

```bash
# 1. Configurer les credentials
cp .env.example .env
# Éditer .env avec vos valeurs

# 2. Lancer la stack
docker compose up -d

# 3. Build + run initial du speedtest
docker compose build speedtest
docker compose run --rm speedtest

# 4. Installer les timers systemd (remplace crontab)
just install-timers
```

## Maintenance (`just`)

> Prérequis : [just](https://github.com/casey/just) ≥ 1.49 — `just --list` pour voir toutes les recettes.

### Stack Lifecycle

| Commande                 | Description                                                               |
| ------------------------ | ------------------------------------------------------------------------- |
| `just up`                | Démarrer la stack                                                         |
| `just stop`              | Arrêter (préserve les données)                                            |
| `just restart`           | Redémarrer tous les services                                              |
| `just restart-svc <svc>` | Redémarrer un seul service (ex: `just restart-svc grafana`)               |
| `just down`              | Supprimer les containers (préserve les volumes)                           |
| `just deploy`            | Build speedtest + pull images + recreate                                  |
| `just nuke`              | Supprimer containers **et** volumes (⚠️ destructif, confirmation requise) |

### Monitoring & Diagnostics

| Commande                  | Description                                 |
| ------------------------- | ------------------------------------------- |
| `just status`             | État des containers et health checks        |
| `just check`              | Health check rapide (4 services)            |
| `just versions`           | Versions de tous les services               |
| `just stats`              | Statistiques : bases, compteurs, disk usage |
| `just logs [N]`           | Dernières N lignes de logs (défaut: 50)     |
| `just logs-svc <svc> [N]` | Logs d'un service spécifique                |
| `just logs-follow`        | Suivre les logs en temps réel               |

### Data

| Commande                | Description                                    |
| ----------------------- | ---------------------------------------------- |
| `just speedtest`        | Lancer un speedtest manuellement (hors cron)   |
| `just last-results [N]` | Derniers N résultats speedtest (défaut: 5)     |
| `just backup`           | Backup complet : dashboards Grafana + InfluxDB |

### Build & Cleanup

| Commande           | Description                                       |
| ------------------ | ------------------------------------------------- |
| `just build`       | Build l'image speedtest                           |
| `just build-clean` | Rebuild sans cache                                |
| `just clean`       | Supprimer containers arrêtés + images orphelines  |
| `just clean-all`   | Clean + supprimer toutes les images non utilisées |

### Testing

| Commande     | Description                              |
| ------------ | ---------------------------------------- |
| `just test`  | Suite de régression complète (17 checks) |
| `just check` | Health check rapide des 4 services       |

### Publication & Preview

| Commande                  | RPi requis | Description                                                            |
| ------------------------- | ---------- | ---------------------------------------------------------------------- |
| `just publish [N]`        | **oui**    | Publier avec données fraîches InfluxDB (N jours, défaut: 30)           |
| `just publish-template`   | non        | Publier le template mis à jour (réutilise les données de la page live) |
| `just preview [N]`        | **oui**    | Prévisualiser avec données InfluxDB locales (`http://localhost:8080`)  |
| `just preview-template`   | non        | Prévisualiser le template mis à jour avant publish                     |
| `just preview-dev [port]` | non        | Prévisualiser avec données live GitHub Pages (défaut: 8080)            |

### Scheduling (systemd timers)

| Commande                | Description                                             |
| ----------------------- | ------------------------------------------------------- |
| `just install-timers`   | Installer les timers systemd user (speedtest + publish) |
| `just uninstall-timers` | Désinstaller les timers                                 |
| `just timer-status`     | État des timers + logs récents                          |

Les timers remplacent le crontab : la configuration est versionnée dans `systemd/`, installée via `just install-timers`, et visible via `systemctl --user list-timers`. Logs consultables avec `journalctl --user -u speedtest` / `-u publish-gh-pages`.

### Utilitaires

| Commande            | Description                  |
| ------------------- | ---------------------------- |
| `just alerts`       | État des alertes (✅/🔴)     |
| `just influx-shell` | Shell InfluxDB interactif    |
| `just shell <svc>`  | Shell bash dans un container |

## Configuration

Les credentials sont dans `.env` (non versionné). Copier `.env.example` :

```bash
cp .env.example .env
```

## Dashboards

| Dashboard           | UID                    | Dossier    | Description                              |
| ------------------- | ---------------------- | ---------- | ---------------------------------------- |
| SpeedTest           | `Ha9ke1iRk`            | General    | Download, upload, ping                   |
| System              | `000000128`            | General    | CPU, RAM, disk, réseau, température      |
| Docker Containers   | `rpi-docker-dashboard` | General    | CPU, RAM, réseau, I/O par container      |
| RPi Alerts Overview | `rpi-alerts-dashboard` | RPi Alerts | Gauges + graphiques avec seuils d'alerte |

## Alertes

6 alertes Grafana provisionées automatiquement (`grafana/provisioning/alerting/`) :

| Alerte               | Seuil                    | Durée  | Sévérité |
| -------------------- | ------------------------ | ------ | -------- |
| High CPU Usage       | > 80%                    | 5 min  | warning  |
| High CPU Temperature | > 70°C                   | 2 min  | critical |
| High RAM Usage       | > 85%                    | 5 min  | warning  |
| High Swap Usage      | > 50%                    | 10 min | warning  |
| High Disk Usage      | > 85%                    | 10 min | warning  |
| High Load Average    | > 4 (= 100% des 4 cores) | 5 min  | warning  |

Le dashboard **RPi Alerts Overview** affiche les 6 métriques surveillées avec les seuils d'alerte en rouge sur les graphiques, plus un panneau d'historique des alertes.

Visibles dans Grafana → Alerting → Alert rules, ou via `just alerts`.

## Données

- **speedtest** : résultats Ookla (download, upload, ping) — rétention infinie
- **telegraf** : métriques système (CPU, RAM, disk, température) — rétention 90 jours

## Backup

```bash
just backup    # Crée un dossier horodaté dans backups/ avec dashboards + InfluxDB
```

## Tests

```bash
just test      # 17 checks: services, dashboards, pipeline, data integrity
just check     # Health check rapide (4 services)
```

## GitHub Pages — Vue externe

Page statique publique avec les résultats speedtest des 30 derniers jours :

**https://yoyonel.github.io/rpi-internet-monitoring/**

### Design & rendu

- **Thème sombre** inspiré de [tsbench](https://mibayy.github.io/tsbench/) : CSS variables, police Geist + Geist Mono (Google Fonts), `backdrop-filter` nav, panels `border-radius:8px`
- **Stats détaillées** : chaque carte affiche la **médiane** comme valeur principale + sous-métriques (min / avg / max / last pour bandwidth, min / med / p95 / max pour ping), nombre de points et plage temporelle active
- **Alertes RPi** : état des 6 alertes Grafana avec badges ok/firing/pending, températures converties en °C

### Rendu dual-mode adaptatif

| Fenêtre                  | Mode               | Détail                                                                                        |
| ------------------------ | ------------------ | --------------------------------------------------------------------------------------------- |
| ≤ 48h (6h, 12h, 24h, 2j) | **Line chart**     | Courbes LTTB (600 pts max) avec gradient fill                                                 |
| > 48h (7j, 30j)          | **Band chart IQR** | Bandes Q1↔Q3 + ligne médiane + whiskers min/max par bucket temporel (2h pour 7j, 6h pour 30j) |

Le mode band chart est inspiré des boxplots : au lieu de tracer des milliers de points illisibles, les données sont agrégées en buckets temporels et chaque bucket affiche sa distribution statistique. Résultat : rendu instantané même sur 30 jours, et visualisation immédiate de la dispersion et des anomalies.

### Stack technique (pages)

| Technologie                                                                                                              | Usage                                              |
| ------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------- |
| [Chart.js 4](https://www.chartjs.org/) + [chartjs-adapter-date-fns](https://github.com/chartjs/chartjs-adapter-date-fns) | Graphiques temps-réel                              |
| [LTTB](https://skemman.is/bitstream/1946/15343/3/SS_MSthesis.pdf)                                                        | Downsampling préservant les pics                   |
| Float64Array                                                                                                             | Stockage mémoire compact, itération cache-friendly |
| requestAnimationFrame                                                                                                    | Debounce du rendering                              |
| Geist / Geist Mono                                                                                                       | Typographie (Google Fonts)                         |

### Commandes

**Depuis le RPi** (données fraîches InfluxDB) :

```bash
just publish         # Publication complète (30 jours de données InfluxDB → GH Pages)
just publish 7       # 7 jours d'historique seulement
just preview         # Prévisualiser avant de publier (http://localhost:8080)
```

**Depuis n'importe quel poste** (réutilise les données de la page live) :

```bash
just publish-template   # Met à jour le template HTML/CSS/JS sur GH Pages
just preview-template   # Prévisualiser le template avant de publier
just preview-dev        # Prévisualiser avec les données live (http://localhost:8080)
```

`publish-template` est utile quand on modifie le design, les stats, ou les graphiques sans avoir accès au RPi : il récupère les données actuelles de la page live, les injecte dans le template local, et pousse le résultat sur GitHub Pages.

### Développement

Le workflow de développement du template ne nécessite pas le RPi :

```bash
# 1. Modifier gh-pages/index.template.html
# 2. Prévisualiser localement
just preview-template    # ou just preview-dev
# 3. Quand c'est prêt, publier
just publish-template
```

La publication des **données fraîches** est automatisée via les timers systemd sur le RPi (`just install-timers`). Les timers relancent speedtest et publish toutes les 10 minutes avec un délai aléatoire pour éviter la contention.

## Références

- [Monitorer son débit internet](https://blog.eleven-labs.com/fr/monitorer-son-debit-internet/) (article original)
