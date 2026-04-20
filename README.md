# Monitoring Débit Internet — RPi4

[![Lint](https://github.com/yoyonel/rpi-internet-monitoring/actions/workflows/lint.yml/badge.svg)](https://github.com/yoyonel/rpi-internet-monitoring/actions/workflows/lint.yml)
[![E2E Nightly — Production](https://github.com/yoyonel/rpi-internet-monitoring/actions/workflows/e2e-nightly.yml/badge.svg)](https://github.com/yoyonel/rpi-internet-monitoring/actions/workflows/e2e-nightly.yml)
[![Sim Stack E2E — Nightly](https://github.com/yoyonel/rpi-internet-monitoring/actions/workflows/sim-e2e-nightly.yml/badge.svg)](https://github.com/yoyonel/rpi-internet-monitoring/actions/workflows/sim-e2e-nightly.yml)
[![Deploy GitHub Pages](https://github.com/yoyonel/rpi-internet-monitoring/actions/workflows/deploy-gh-pages.yml/badge.svg)](https://github.com/yoyonel/rpi-internet-monitoring/actions/workflows/deploy-gh-pages.yml)
[![GitHub Pages](https://img.shields.io/website?url=https%3A%2F%2Fyoyonel.github.io%2Frpi-internet-monitoring%2F&label=GitHub%20Pages)](https://yoyonel.github.io/rpi-internet-monitoring/)

[![Lighthouse Performance (mobile)](https://img.shields.io/endpoint?url=https://yoyonel.github.io/rpi-internet-monitoring/badges/lighthouse-performance-mobile.json)](https://github.com/yoyonel/rpi-internet-monitoring/actions/workflows/lighthouse.yml)
[![Lighthouse Performance (desktop)](https://img.shields.io/endpoint?url=https://yoyonel.github.io/rpi-internet-monitoring/badges/lighthouse-performance-desktop.json)](https://github.com/yoyonel/rpi-internet-monitoring/actions/workflows/lighthouse.yml)
[![Lighthouse Accessibility](https://img.shields.io/endpoint?url=https://yoyonel.github.io/rpi-internet-monitoring/badges/lighthouse-accessibility-desktop.json)](https://github.com/yoyonel/rpi-internet-monitoring/actions/workflows/lighthouse.yml)
[![Lighthouse Best Practices](https://img.shields.io/endpoint?url=https://yoyonel.github.io/rpi-internet-monitoring/badges/lighthouse-best-practices-desktop.json)](https://github.com/yoyonel/rpi-internet-monitoring/actions/workflows/lighthouse.yml)
[![Lighthouse SEO](https://img.shields.io/endpoint?url=https://yoyonel.github.io/rpi-internet-monitoring/badges/lighthouse-seo-desktop.json)](https://github.com/yoyonel/rpi-internet-monitoring/actions/workflows/lighthouse.yml)

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

| Commande                  | Description                                               |
| ------------------------- | --------------------------------------------------------- |
| `just speedtest`          | Lancer un speedtest manuellement (hors cron)              |
| `just last-results [N]`   | Derniers N résultats speedtest (défaut: 5)                |
| `just backup`             | Backup complet + rotation auto (garde les 5 derniers)     |
| `just backup-rotate [N]`  | Rotation manuelle : garder les N plus récents (défaut: 5) |
| `just backup-check <dir>` | Vérification intégrité offline (gzip -t, JSON)            |

### Build & Cleanup

| Commande           | Description                                       |
| ------------------ | ------------------------------------------------- |
| `just build`       | Build l'image speedtest                           |
| `just build-clean` | Rebuild sans cache                                |
| `just clean`       | Supprimer containers arrêtés + images orphelines  |
| `just clean-all`   | Clean + supprimer toutes les images non utilisées |

### Testing

| Commande                     | RPi requis | Description                                                     |
| ---------------------------- | ---------- | --------------------------------------------------------------- |
| `just test`                  | **oui**    | Suite de régression complète (17 checks)                        |
| `just check`                 | **oui**    | Health check rapide des 4 services                              |
| `just e2e [url]`             | non        | Tests E2E Playwright contre une preview (défaut: :8080)         |
| `just sim-test`              | non        | Smoke tests de la stack sim (25 checks)                         |
| `just lint`                  | non        | Vérifier le formatage et le linting de tous les sources         |
| `just fmt`                   | non        | Auto-formater tous les fichiers sources                         |
| `just lighthouse [flags]`    | non        | Audit Lighthouse sur la page prod (mobile+desktop par défaut)   |
| `just lighthouse-report [p]` | non        | Analyse priorisée des rapports Lighthouse (mobile/desktop/both) |

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

### Simulation RPi4 (ARM64 sur x86)

Stack de simulation locale : tous les containers tournent en ARM64 via QEMU, reproduisant l'architecture du RPi4 de production. Voir [docs/sim-environment.md](docs/sim-environment.md) pour le détail complet.

| Commande                        | Description                                         |
| ------------------------------- | --------------------------------------------------- |
| `just sim-binfmt`               | Enregistrer les handlers QEMU (1× par reboot)       |
| `just sim-up`                   | Démarrer la stack sim complète                      |
| `just sim-stop`                 | Arrêter (préserve l'état)                           |
| `just sim-down`                 | Supprimer les containers (préserve les volumes)     |
| `just sim-nuke`                 | Supprimer containers **et** volumes (⚠️ destructif) |
| `just sim-status`               | État des containers + health checks                 |
| `just sim-logs`                 | Dernières 50 lignes de logs                         |
| `just sim-build`                | Build l'image speedtest pour ARM64                  |
| `just sim-speedtest`            | Lancer un speedtest manuellement                    |
| `just sim-test`                 | Suite de smoke tests (25 checks)                    |
| `just sim-stats`                | Bases de données, rétention, compteurs              |
| `just sim-restore-backup <dir>` | Restaurer un backup RPi dans la sim                 |
| `just sim-verify-backup`        | Vérifier l'intégrité des données restaurées         |
| `just sim-test-backup <dir>`    | Pipeline complet : nuke → restore → verify          |

Grafana : <http://localhost:3000> (admin / simpass) — Chronograf : <http://localhost:8888>

### Utilitaires

| Commande             | Description                                    |
| -------------------- | ---------------------------------------------- |
| `just alerts`        | État des alertes (✅/🔴)                       |
| `just influx-shell`  | Shell InfluxDB interactif                      |
| `just shell <svc>`   | Shell bash dans un container                   |
| `just install-hooks` | Installe les git hooks (pre-commit + pre-push) |

### Git hooks

Installer avec `just install-hooks`. Deux hooks sont fournis :

| Hook         | Déclencheur  | Action                                                                                          |
| ------------ | ------------ | ----------------------------------------------------------------------------------------------- |
| `pre-commit` | `git commit` | Lint & format check sur les fichiers stagés (sh, py, yaml, html, css, js, json, md, Dockerfile) |
| `pre-push`   | `git push`   | E2E tests Playwright (démarre un serveur preview si nécessaire)                                 |

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
               # + rotation automatique (garde les 5 derniers, configurable via BACKUP_KEEP)

just backup-rotate      # Rotation manuelle (garde 5)
just backup-rotate 3    # Rotation manuelle (garde 3)
```

### Validation et restauration

Outils pour vérifier et restaurer des backups RPi dans la stack sim locale. Voir [docs/backup-restore-tooling.md](docs/backup-restore-tooling.md) pour le détail complet.

```bash
# Vérification offline (pas besoin de stack)
just backup-check backups-rpi/20260416-205640

# Restauration dans la sim
just sim-restore-backup backups-rpi/20260416-205640
just sim-verify-backup

# Pipeline complet (nuke + start + check + restore + verify)
just sim-test-backup backups-rpi/20260416-205640
```

## Tests

```bash
just test      # 17 checks: services, dashboards, pipeline, data integrity (RPi)
just check     # Health check rapide des 4 services (RPi)
```

### Tests E2E (Playwright)

Tests fonctionnels de la page GitHub Pages exécutés dans un **navigateur headless Chromium** via [Playwright](https://playwright.dev/). Contrairement à des smoke tests HTTP (curl), ces tests valident le **comportement métier réel** : exécution du JavaScript, parsing des données, rendu des charts, interactivité.

#### Prérequis

```bash
npm ci                             # installe @playwright/test
npx playwright install chromium    # télécharge Chromium headless (~112 Mo)
```

#### Usage

```bash
# 1. Lancer une preview locale (terminal 1)
just preview-dev

# 2. Lancer les tests (terminal 2)
just e2e                          # contre http://localhost:8080 (défaut)
just e2e http://localhost:9090    # port alternatif

# Contre une URL distante (preview Surge, production…)
just e2e https://yoyonel-rpi-internet-monitoring-preview-pr-2.surge.sh
just e2e https://yoyonel.github.io/rpi-internet-monitoring/
```

#### Couverture des tests

12 tests dans [tests/e2e.spec.js](tests/e2e.spec.js) organisés en 2 groupes (7 domaines) :

**Read-only checks** (9 tests, page partagée — une seule navigation) :

| #   | Test                                          | Domaine        | Ce qu'il valide                                                                                   |
| --- | --------------------------------------------- | -------------- | ------------------------------------------------------------------------------------------------- |
| 1   | `no JavaScript errors in console`             | Runtime JS     | Aucune exception non catchée dans `window.onerror` / `console.error`                              |
| 2   | `stats cards display values`                  | Rendu stats    | 3 cartes (Download, Upload, Ping) présentes, chacune avec une valeur numérique dans `.v`          |
| 3   | `bandwidth chart has data`                    | Chart.js       | `Chart.getChart('bwChart')` a ≥ 1 dataset avec des data points                                    |
| 4   | `ping chart has data`                         | Chart.js       | `Chart.getChart('piChart')` a ≥ 1 dataset avec des data points                                    |
| 5   | `alerts are displayed`                        | Alertes        | Section `#alertsSec` visible, ≥ 1 `.al-row` avec `.al-name` et `.al-badge` non vides              |
| 6   | `no unreplaced template placeholders`         | Build pipeline | Aucun `__SPEEDTEST_DATA__`, `__ALERTS_DATA__`, `__LAST_UPDATE__`, `__GENERATED_AT__` dans le HTML |
| 7   | `data contains a reasonable number of points` | Données        | `RAW_DATA.results[0].series[0].values.length > 100` (≈ 144 pts/jour à 10 min)                     |
| 8   | `drag-to-zoom plugin is configured on charts` | Zoom           | Plugin zoom activé en mode drag sur l'axe X pour les deux charts                                  |
| 9   | `capture preview screenshot`                  | CI             | Screenshot pleine page pour commentaire PR (attend fin des animations Chart.js)                   |

**Interactive** (3 tests, page partagée, exécution sérielle) :

| #   | Test                                                | Domaine       | Ce qu'il valide                                                                          |
| --- | --------------------------------------------------- | ------------- | ---------------------------------------------------------------------------------------- |
| 10  | `time range buttons update the view`                | Interactivité | Clic sur le bouton "6h" change le texte de `#rangeLabel`                                 |
| 11  | `double-click on chart resets to live view`         | Interactivité | Double-clic sur le chart bandwidth réinitialise à la vue 48h                             |
| 12  | `time range picker opens with calendar and presets` | Picker        | Ouverture du picker, présence du calendrier, présets relatifs, fermeture après sélection |

#### Ce qui n'est PAS couvert

- **Rendu visuel pixel-perfect** (pas de screenshot comparison) — trop fragile pour ce projet
- **Responsive / mobile** — un seul viewport (desktop Chromium par défaut)
- **Performance / temps de chargement** — pas de budget perf
- **Navigation entre pages** — single page, pas de routing

#### Architecture technique

```
playwright.config.js     → Config : testDir, baseURL via E2E_BASE_URL, Chromium only,
                            timeouts adaptatifs (local vs remote)
tests/e2e.spec.js        → 12 tests en 2 groupes, ~210 lignes
Justfile (just e2e)      → Point d'entrée local : E2E_BASE_URL=<url> npx playwright test
```

Le `baseURL` est configurable via la variable d'environnement `E2E_BASE_URL` (défaut: `http://localhost:8080`). Cela permet d'exécuter les mêmes tests contre n'importe quel déploiement : local, Surge preview, ou production.

#### Stratégie de stabilité

Les tests E2E sont conçus pour être **rapides et non-flaky**, même contre des URLs distantes (GitHub Pages, Surge) :

| Technique                        | Impact                                                                                  |
| -------------------------------- | --------------------------------------------------------------------------------------- |
| **Page partagée par groupe**     | 2 navigations au lieu de 12 → ~5s au lieu de ~4 min contre GH Pages                     |
| **`waitForAppReady()`**          | Attend que stats + charts soient rendus (pas de `waitForTimeout` magique)               |
| **`waitUntil: 'commit'`**        | Navigation rapide, la readiness est vérifiée par JS plutôt que par les sous-ressources  |
| **Timeouts adaptatifs**          | `timeout`, `navigationTimeout`, `retries` augmentés automatiquement pour les URLs HTTPS |
| **Locators Playwright**          | `page.locator().click()` au lieu de `page.click()` → auto-attente d'actionabilité       |
| **Animation guard (screenshot)** | `waitForFunction(!chart.animating)` au lieu d'un délai fixe                             |
| **État défensif (picker)**       | Guard `Escape` si le picker est resté ouvert d'un test précédent                        |

#### Pipeline CI

Les tests E2E s'exécutent automatiquement dans le workflow **Preview PR — Surge** (`.github/workflows/preview-pr.yml`) :

1. Build de la page avec les données live
2. Déploiement sur Surge.sh
3. `npm ci` + installation de Chromium headless
4. Exécution des 12 tests Playwright contre l'URL Surge déployée
5. Retry automatique (2 retries par test en cas de flakiness réseau Surge)

Déclenché sur chaque PR modifiant : `gh-pages/**`, `scripts/*.py`, `tests/**`, `playwright.config.js`.

### Code Quality

```bash
just lint      # Vérifier tous les fichiers
just fmt       # Auto-formater tous les fichiers
```

| Outil      | Fichiers ciblés                     |
| ---------- | ----------------------------------- |
| shellcheck | `.sh`                               |
| shfmt      | `.sh` (indent 4, case indent)       |
| hadolint   | `Dockerfile`                        |
| yamllint   | `.yml`                              |
| prettier   | HTML, CSS, JS, JSON, YAML, Markdown |
| ruff       | Python (lint + format)              |

La CI exécute `just lint` sur chaque push et PR via `.github/workflows/lint.yml`.

#### Sim Stack — Nightly E2E

Un workflow dédié (`.github/workflows/sim-e2e-nightly.yml`) démarre la stack ARM64 complète sur un runner Ubuntu chaque nuit (03:30 UTC) et exécute les 25 smoke tests. Déclenchable manuellement via l'onglet **Actions** → **Sim Stack E2E — Nightly** → **Run workflow** pour valider une PR.

#### Lighthouse Audit

Le workflow `.github/workflows/lighthouse.yml` lance des audits Lighthouse **Mobile** et **Desktop** contre la page de production. Il se déclenche :

- **automatiquement** après chaque déploiement GitHub Pages (via `workflow_run`)
- **hebdomadairement** (lundi 06:00 UTC)
- **manuellement** (onglet **Actions** → **Lighthouse Audit** → **Run workflow**)

Chaque run produit :

- Un **Job Summary** avec tableau de scores et badges colorés (🟢 ≥90, 🟠 ≥50, 🔴 <50)
- Les rapports HTML et JSON en artifacts (rétention 30 jours)

## GitHub Pages — Vue externe

Page statique publique avec les résultats speedtest des 30 derniers jours :

**https://yoyonel.github.io/rpi-internet-monitoring/**

### Design & rendu

- **Thème sombre** inspiré de [tsbench](https://mibayy.github.io/tsbench/) : CSS variables, police Geist + Geist Mono (Google Fonts), `backdrop-filter` nav, panels `border-radius:8px`
- **Stats détaillées** : chaque carte affiche la **médiane** comme valeur principale + sous-métriques (min / avg / max / last pour bandwidth, min / med / p95 / max pour ping), nombre de points et plage temporelle active
- **Alertes RPi** : état des 6 alertes Grafana avec badges ok/firing/pending, températures converties en °C, horodatage de la dernière évaluation Grafana

> **Note** : l'horodatage des alertes (`Dernière évaluation : ...`) n'est disponible qu'après une publication depuis le RPi (`just publish`), car c'est le seul moment où `publish-gh-pages.sh` interroge l'API Grafana. Le format legacy (tableau simple sans timestamp) reste supporté — dans ce cas la date n'est simplement pas affichée.

- **Drag-to-zoom** : sélection au clic-glissé sur les graphiques pour zoomer sur une plage temporelle (style Grafana). Les deux charts se synchronisent automatiquement. Double-clic pour revenir à la vue 48 h live
- **Sélecteur de plage temporelle** (style Grafana) : clic sur la plage affichée ouvre un panneau avec calendrier, entrées From/To absolues, présets relatifs (5 min → 30 jours), et historique des plages récentes

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
| [chartjs-plugin-zoom](https://www.chartjs.org/chartjs-plugin-zoom/) + [Hammer.js](https://hammerjs.github.io/)           | Drag-to-zoom sur l'axe X (sélection brush)         |
| [LTTB](https://skemman.is/bitstream/1946/15343/3/SS_MSthesis.pdf)                                                        | Downsampling préservant les pics                   |
| Float64Array                                                                                                             | Stockage mémoire compact, itération cache-friendly |
| requestAnimationFrame                                                                                                    | Debounce du rendering                              |
| Geist / Geist Mono                                                                                                       | Typographie (Google Fonts, async preload)          |

### Performance & Accessibilité

Optimisations appliquées pour maximiser les scores [Lighthouse](https://developer.chrome.com/docs/lighthouse/) :

| Optimisation                                                    | Impact                                           |
| --------------------------------------------------------------- | ------------------------------------------------ |
| `defer` sur tous les `<script>` CDN                             | Élimine le render-blocking JS (-1.2 s mobile)    |
| Preload async des Google Fonts                                  | Élimine le render-blocking CSS font              |
| Auto-refresh via `setTimeout` (pas `<meta http-equiv=refresh>`) | Accessibilité : pas de refresh inattendu         |
| `<main>` landmark                                               | Screen readers : navigation structurée           |
| `<meta name="description">`                                     | SEO : description dans les résultats             |
| Contrastes WCAG AA (≥ 4.5:1)                                    | `--text2` 7.7:1, `--text3` 5.8:1, `.rb.on` 9.2:1 |
| Liens distinguables (underline)                                 | Pas de dépendance couleur seule                  |
| `<link rel="icon" href="data:,">`                               | Supprime l'erreur console 404 favicon            |

**Scores Lighthouse (avril 2026)** :

|                | Mobile | Desktop |
| -------------- | :----: | :-----: |
| Performance    | 🟠 ~60 | 🟠 ~80  |
| Accessibility  | 🟢 100 | 🟢 100  |
| Best Practices | 🟢 100 | 🟢 100  |
| SEO            | 🟢 100 | 🟢 100  |

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

### Audit Lighthouse (local)

Deux commandes pour auditer et analyser les performances de la page de production :

```bash
just lighthouse              # Lancer les audits Mobile + Desktop
just lighthouse --mobile     # Mobile seul
just lighthouse --desktop    # Desktop seul
just lighthouse --both --open  # Les deux + ouvrir les rapports HTML
```

```bash
just lighthouse-report         # Analyse priorisée (mobile + desktop)
just lighthouse-report mobile  # Mobile seul
just lighthouse-report desktop # Desktop seul
```

Le rapport affiche les scores, les quick wins (accessibilité, SEO) et les opportunités de performance classées par priorité (HIGH/MEDIUM/LOW) avec les savings estimés et les ressources impactées.

Les rapports sont stockés dans `lighthouse-reports/` (gitignored) avec des symlinks `latest-*.report.{html,json}` pointant toujours sur le dernier run.

**Prérequis** : `npm install -g lighthouse`

**Workflow typique** : `just lighthouse` → `just lighthouse-report` → corriger → re-auditer.

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
