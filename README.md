# Monitoring Débit Internet — RPi4

Stack Docker pour monitorer le débit internet (download, upload, ping) via [Ookla Speedtest CLI](https://www.speedtest.net/apps/cli), avec stockage dans InfluxDB et visualisation dans Grafana.

## Architecture

```
┌──────────┐  cron */10  ┌───────────┐   write    ┌──────────┐
│  crontab │────────────▶│ speedtest │───────────▶│ InfluxDB │
└──────────┘             └───────────┘            │  1.8.10  │
                                                  └────┬─────┘
┌──────────┐   collect   ┌───────────┐   write         │
│  System  │────────────▶│ Telegraf  │─────────────────▶│
│  metrics │             │  1.38.2   │                  │
└──────────┘             └───────────┘                  │
                                                        │
                         ┌───────────┐   query          │
                         │  Grafana  │◀─────────────────┘
                         │  11.6.14  │
                         └───────────┘
                         ┌────────────┐  query
                         │ Chronograf │◀────────────────┘
                         │   1.9.4    │
                         └────────────┘
```

## Services

| Service | Version | Port | Description |
|---|---|---|---|
| Grafana | 12.4.3 | 3000 | Dashboards (SpeedTest, System, Docker, RPi Alerts) |
| InfluxDB | 1.8.10 | 8086 (interne) | Time-series DB |
| Chronograf | 1.9.4 | 8888 | Admin InfluxDB |
| Telegraf | 1.38.2 | — | Métriques système (CPU, RAM, disk, temp) |
| Speedtest | bookworm | — | Test débit Ookla, toutes les 10 min |

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

# 4. Configurer le cron (toutes les 10 min)
crontab -e
# Ajouter: */10 * * * * cd /path/to/project && /usr/bin/docker compose run --rm speedtest >/dev/null 2>&1
```

## Maintenance (`just`)

> Prérequis : [just](https://github.com/casey/just) ≥ 1.49 — `just --list` pour voir toutes les recettes.

### Stack Lifecycle

| Commande | Description |
|---|---|
| `just up` | Démarrer la stack |
| `just stop` | Arrêter (préserve les données) |
| `just restart` | Redémarrer tous les services |
| `just restart-svc <svc>` | Redémarrer un seul service (ex: `just restart-svc grafana`) |
| `just down` | Supprimer les containers (préserve les volumes) |
| `just deploy` | Build speedtest + pull images + recreate |
| `just nuke` | Supprimer containers **et** volumes (⚠️ destructif, confirmation requise) |

### Monitoring & Diagnostics

| Commande | Description |
|---|---|
| `just status` | État des containers et health checks |
| `just check` | Health check rapide (4 services) |
| `just versions` | Versions de tous les services |
| `just stats` | Statistiques : bases, compteurs, disk usage |
| `just logs [N]` | Dernières N lignes de logs (défaut: 50) |
| `just logs-svc <svc> [N]` | Logs d'un service spécifique |
| `just logs-follow` | Suivre les logs en temps réel |

### Data

| Commande | Description |
|---|---|
| `just speedtest` | Lancer un speedtest manuellement (hors cron) |
| `just last-results [N]` | Derniers N résultats speedtest (défaut: 5) |
| `just backup` | Backup complet : dashboards Grafana + InfluxDB |

### Build & Cleanup

| Commande | Description |
|---|---|
| `just build` | Build l'image speedtest |
| `just build-clean` | Rebuild sans cache |
| `just clean` | Supprimer containers arrêtés + images orphelines |
| `just clean-all` | Clean + supprimer toutes les images non utilisées |

### Testing

| Commande | Description |
|---|---|
| `just test` | Suite de régression complète (17 checks) |
| `just check` | Health check rapide des 4 services |

### Utilitaires

| Commande | Description |
|---|---|
| `just alerts` | État des alertes (✅/🔴) |
| `just influx-shell` | Shell InfluxDB interactif |
| `just shell <svc>` | Shell bash dans un container |
| `just cron` | Afficher le crontab actif |

## Configuration

Les credentials sont dans `.env` (non versionné). Copier `.env.example` :

```bash
cp .env.example .env
```

## Dashboards

| Dashboard | UID | Dossier | Description |
|---|---|---|---|
| SpeedTest | `Ha9ke1iRk` | General | Download, upload, ping |
| System | `000000128` | General | CPU, RAM, disk, réseau, température |
| Docker Containers | `rpi-docker-dashboard` | General | CPU, RAM, réseau, I/O par container |
| RPi Alerts Overview | `rpi-alerts-dashboard` | RPi Alerts | Gauges + graphiques avec seuils d'alerte |

## Alertes

6 alertes Grafana provisionées automatiquement (`grafana/provisioning/alerting/`) :

| Alerte | Seuil | Durée | Sévérité |
|---|---|---|---|
| High CPU Usage | > 80% | 5 min | warning |
| High CPU Temperature | > 70°C | 2 min | critical |
| High RAM Usage | > 85% | 5 min | warning |
| High Swap Usage | > 50% | 10 min | warning |
| High Disk Usage | > 85% | 10 min | warning |
| High Load Average | > 4 (= 100% des 4 cores) | 5 min | warning |

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

## Références

- [Monitorer son débit internet](https://blog.eleven-labs.com/fr/monitorer-son-debit-internet/) (article original)
