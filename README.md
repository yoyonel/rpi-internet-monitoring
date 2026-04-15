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
| Grafana | 11.6.14 | 3000 | Dashboards (SpeedTest, System) |
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

## Configuration

Les credentials sont dans `.env` (non versionné). Copier `.env.example` :

```bash
cp .env.example .env
```

## Données

- **speedtest** : résultats Ookla (download, upload, ping) — rétention infinie
- **telegraf** : métriques système (CPU, RAM, disk, température) — rétention 90 jours

## Tests

```bash
./test-stack.sh    # 17 checks: services, dashboards, pipeline, data integrity
```

## Références

- [Monitorer son débit internet](https://blog.eleven-labs.com/fr/monitorer-son-debit-internet/) (article original)
