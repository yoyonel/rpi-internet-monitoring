# Data Pipeline — Du speedtest à la page web

> Comment les données circulent depuis le Raspberry Pi jusqu'à la page publique
> https://yoyonel.github.io/rpi-internet-monitoring/

---

## Vue d'ensemble

```
┌─────────────┐    ┌───────────┐    ┌──────────────┐    ┌────────────┐
│  Speedtest   │───▶│ InfluxDB  │◀───│  Telegraf     │◀───│ docker-    │
│  (10 min)    │    │           │    │  (20s)        │    │ socket-    │
└─────────────┘    │           │    └──────────────┘    │ proxy      │
                   │  speedtest│                        └────────────┘
                   │  telegraf │                              ▲
                   └─────┬─────┘                         /var/run/
                         │                              docker.sock
                         ▼
              ┌─────────────────────┐
              │  publish-gh-pages   │
              │  (10 min)           │
              │  query + render     │
              └──────────┬──────────┘
                         │ git push
                         ▼
              ┌─────────────────────┐
              │  GitHub Pages CDN   │
              │  (rebuild ~2 min)   │
              │  (cache ~10 min)    │
              └─────────────────────┘
```

Trois flux de données alimentent le système :

1. **Speedtest** → mesure le débit internet toutes les 10 minutes
2. **Telegraf** → collecte les métriques système toutes les 20 secondes
3. **Publish** → génère et pousse la page web toutes les 10 minutes

---

## Pipeline 1 : Speedtest

### Déclenchement

Le timer systemd `speedtest.timer` déclenche un run toutes les 10 minutes,
avec un délai aléatoire de 0-30s pour éviter les pics réseau.

```
speedtest.timer (systemd user timer)
  → OnCalendar=*:0/10
  → RandomizedDelaySec=30
  → Persistent=true (rattrapage si le RPi était éteint)
```

### Exécution

```
speedtest.service
  → docker compose run --rm speedtest
  → Container éphémère (non-root, user speedtest-user)
```

Le container `speedtest` :

1. Lance le CLI Ookla Speedtest (`speedtest --format=json`)
2. Parse le résultat JSON (download, upload, ping, jitter, packet loss, serveur)
3. Écrit le résultat dans InfluxDB via l'API HTTP (`POST /write?db=speedtest`)

### Authentification

Les credentials InfluxDB (`INFLUXDB_USER` / `INFLUXDB_USER_PASSWORD`) sont injectés
via les variables d'environnement du `docker-compose.yml`.
Les mots de passe ne sont jamais exposés dans `/proc/cmdline` — le script utilise
`curl -K <(...)` (process substitution) pour passer les credentials.

### Données stockées

- **Base** : `speedtest`
- **Measurement** : `speedtest`
- **Champs** : `download_bandwidth`, `upload_bandwidth`, `ping_latency`, `ping_jitter`,
  `download_bytes`, `upload_bytes`, `packet_loss`, `server_name`, etc.

### Anti-chevauchement

Le service inclut une `ExecCondition` qui vérifie qu'aucun container `speedtest`
n'est déjà en cours, pour éviter les runs simultanés si un test prend plus de 10 min :

```ini
ExecCondition=/bin/sh -c '! docker ps --format "{{.Names}}" | grep -q speedtest'
```

---

## Pipeline 2 : Métriques système (Telegraf)

### Fonctionnement

Telegraf tourne en continu dans un container permanent. Il collecte les métriques
toutes les **20 secondes** et les flush vers InfluxDB toutes les **10 secondes**.

### Sources de données

| Input                    | Description                                  |
| ------------------------ | -------------------------------------------- |
| `cpu`                    | Utilisation CPU par cœur et total            |
| `mem`                    | RAM utilisée, disponible, cache              |
| `disk`                   | Espace disque par partition                  |
| `diskio`                 | I/O disque (reads/writes)                    |
| `net`                    | Trafic réseau (eth0, wlan0)                  |
| `netstat`                | Connexions TCP/UDP                           |
| `swap`                   | Utilisation swap                             |
| `system`                 | Load average, uptime                         |
| `processes`              | Nombre de processus par état                 |
| `kernel`                 | Statistiques noyau                           |
| `interrupts`             | Interruptions matérielles                    |
| `linux_sysctl_fs`        | Limites filesystem                           |
| `file` (cpu_temperature) | Température CPU via `/sys/class/thermal/`    |
| `docker`                 | Métriques containers via docker-socket-proxy |

### Docker Socket Proxy

Telegraf n'accède **pas** directement au socket Docker. Un proxy
(`tecnativa/docker-socket-proxy`) expose une API restreinte :

```
Telegraf  ──TCP:2375──▶  docker-socket-proxy  ──/var/run/docker.sock──▶  Docker
                         (CONTAINERS=1, INFO=1, tout le reste désactivé)
```

Cela limite la surface d'attaque : même si Telegraf est compromis, il ne peut pas
créer/supprimer des containers ni accéder aux volumes.

### Données stockées

- **Base** : `telegraf`
- **Measurements** : `cpu`, `mem`, `disk`, `docker_container_cpu`,
  `docker_container_mem`, `docker_container_net`, etc.

---

## Pipeline 3 : Publication GitHub Pages

### Déclenchement

Le timer systemd `publish-gh-pages.timer` déclenche la publication toutes les
10 minutes, avec un délai aléatoire de 0-60s :

```
publish-gh-pages.timer (systemd user timer)
  → OnCalendar=*:0/10
  → RandomizedDelaySec=60
  → Persistent=true
```

### Étapes détaillées

#### 3a. Export des données speedtest

Le script `publish-gh-pages.sh` supporte deux backends TSDB :

**InfluxDB** (défaut) :

```bash
influx -execute "SELECT * FROM speedtest WHERE time > now() - 30d"
```

**VictoriaMetrics** (`--backend vm` ou `TSDB_BACKEND=vm`) :

```bash
bash scripts/export-vm-data.sh http://localhost:8428 30
```

Le script `export-vm-data.sh` exporte les 3 métriques speedtest depuis l'API
`/api/v1/export` de VictoriaMetrics (format JSONL), puis délègue la
transformation en format InfluxDB JSON au script Python `vm-to-datajson.py`.

→ Résultat identique quel que soit le backend : fichier `data.json` au format
InfluxDB JSON (~4000+ points), consommé par le frontend sans modification.

#### 3b. Export des alertes Grafana

```bash
curl -K <(...) http://localhost:3000/api/ruler/grafana/api/v1/rules
```

→ Query l'API Grafana pour récupérer les 6 règles d'alerte et leur état actuel
(OK, FIRING, etc.). Résultat : fichier `alerts.json`.

#### 3c. Rendu HTML

```bash
python3 scripts/render-template.py template.html data.json alerts.json index.html
```

Le script `render-template.py` :

1. Lit le template `gh-pages/index.template.html`
2. Injecte les données JSON et les alertes dans les placeholders
3. Calcule les statistiques (médiane, min, max, moyenne, P95, dernier résultat)
4. Génère un `index.html` autonome (~266 KB) avec `app.js` et `style.css` intégrés

#### 3d. Push vers GitHub

```bash
# Dans un répertoire temporaire /tmp/...
git init
git checkout -b gh-pages
touch .nojekyll
git add index.html style.css app.js .nojekyll
git commit -m "Update monitoring data — 2026-04-16T21:01:19+02:00"
git remote add origin https://github.com/yoyonel/rpi-internet-monitoring.git
git fetch origin gh-pages --depth=1
git push --force-with-lease origin gh-pages
```

Le script crée un repo git temporaire, commite les fichiers générés et force-push
sur la branche `gh-pages`. Le `--force-with-lease` protège contre les pertes de
données si quelqu'un d'autre a poussé entre-temps. Le fichier `.nojekyll` empêche
GitHub de lancer un build Jekyll (qui pourrait ignorer certains fichiers).

#### 3e. Déploiement CDN

**Pré-requis** : le repo doit être configuré avec `build_type: legacy`
(Settings > Pages > Source: **Deploy from a branch**). Si la source est
"GitHub Actions", les pushes sur `gh-pages` ne déclenchent aucun rebuild.

Vérifier / corriger via `gh` CLI :

```bash
# Vérifier
gh api repos/<owner>/<repo>/pages | jq .build_type
# Si "workflow", corriger :
echo '{"build_type":"legacy","source":{"branch":"gh-pages","path":"/"}}' | \
  gh api repos/<owner>/<repo>/pages --method PUT --input -
```

Après le push, GitHub :

1. Détecte le nouveau commit sur `gh-pages`
2. Lance un build Pages (~1-3 minutes)
3. Déploie sur le CDN avec `cache-control: max-age=600` (10 min)

**Délai total** entre un push et la visibilité : **~3-15 minutes**
(build GitHub + expiration cache CDN).

---

## Chronologie type (exemple)

```
21:00:00  speedtest.timer se déclenche
21:00:15  Délai aléatoire écoulé, speedtest.service démarre
21:00:16  Container speedtest lancé
21:00:45  Test Ookla terminé, résultat écrit dans InfluxDB (DB speedtest)
21:00:45  Container speedtest supprimé (--rm)
          ▼
21:01:00  publish-gh-pages.timer se déclenche
21:01:30  Délai aléatoire écoulé, publish-gh-pages.service démarre
21:01:31  Query InfluxDB → 4318 points (30 jours)
21:01:32  Query Grafana → 6 alertes
21:01:33  render-template.py → index.html (266 KB)
21:01:35  git push → origin/gh-pages
          ▼
21:02:00  GitHub détecte le push, lance le build Pages
21:03:30  Build terminé, déployé sur le CDN
          ▼
21:03:30  Page accessible (nouveaux visiteurs)
  -21:13  Cache CDN expire pour les visiteurs existants
          ▼
          La page affiche "Mise à jour : 16/04/2026 21:01"
          avec le dernier speedtest de 21:00
```

---

## Persistance et fiabilité

| Mécanisme                   | Rôle                                                                        |
| --------------------------- | --------------------------------------------------------------------------- |
| `Persistent=true` (timers)  | Si le RPi était éteint à l'heure prévue, le run est rattrapé au redémarrage |
| `RandomizedDelaySec`        | Évite que speedtest et publish démarrent exactement en même temps           |
| `loginctl enable-linger`    | Les timers continuent de tourner même sans session SSH active               |
| `ExecCondition` (speedtest) | Empêche les runs parallèles si un test prend plus de 10 min                 |
| `TimeoutStartSec=300`       | Kill le speedtest après 5 min s'il est bloqué                               |
| `--force-with-lease` (git)  | Protège contre les pushes concurrents sur gh-pages                          |

---

## Schéma réseau des containers

```
┌──────────────────────────────────────────────────────────────┐
│                    Réseau Docker "speedtest"                  │
│                                                              │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌────────────┐ │
│  │ influxdb │  │ grafana  │  │chronograf │  │ telegraf   │ │
│  │ :8086    │  │ :3000    │  │ :8888     │  │            │ │
│  │ (interne)│  │ (127.0.0.│  │ (127.0.0. │  │            │ │
│  │          │  │  1 only) │  │  1 only)  │  │            │ │
│  └────▲─────┘  └──────────┘  └───────────┘  └──────┬─────┘ │
│       │                                            │        │
│       │  write                              TCP:2375        │
│       │                                            │        │
│  ┌────┴─────┐                          ┌───────────▼──────┐ │
│  │speedtest │                          │docker-socket-    │ │
│  │(run once)│                          │proxy :2375       │ │
│  └──────────┘                          │ CONTAINERS=1     │ │
│                                        │ INFO=1           │ │
│                                        └────────┬─────────┘ │
│                                                 │            │
└─────────────────────────────────────────────────┼────────────┘
                                                  │
                                         /var/run/docker.sock
                                            (read-only)
```

---

## Commandes de diagnostic

```bash
# Voir quand les prochains runs sont prévus
just timer-status

# Logs des derniers speedtests
journalctl --user -u speedtest.service --no-pager -n 20

# Logs des dernières publications
journalctl --user -u publish-gh-pages.service --no-pager -n 20

# Vérifier que les données arrivent dans InfluxDB
just last-results 3

# Vérifier la date de la page servie par GitHub
curl -sI 'https://yoyonel.github.io/rpi-internet-monitoring/' | grep last-modified

# Tester manuellement un speedtest
just speedtest

# Tester manuellement une publication
just publish
```
