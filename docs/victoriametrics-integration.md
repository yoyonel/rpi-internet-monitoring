# Intégration VictoriaMetrics — État d'avancement

> **Branche** : `feat/victoriametrics`
> **Dernière validation** : 29 avril 2026
> **Statut** : Simulation fonctionnelle, prêt pour migration RPi4

---

## 1. Ce qu'on met en place

VictoriaMetrics (VM) remplace InfluxDB 1.8 comme backend time-series unique.
L'objectif : diviser la RAM par 4–5× sur le RPi4 (de ~400 Mo à ~80 Mo) tout en
gardant la chaîne de collecte, d'export et de visualisation identique.

### Architecture VM-only

```
Telegraf ──→ VictoriaMetrics (:8428/write, InfluxDB line protocol)
                  │
                  ├── API query (:8428/api/v1/query) → export-vm-data.sh → data.json → GitHub Pages
                  ├── API export (:8428/api/v1/export)
                  └── VMUI (:8428/vmui)
Speedtest ──→ VictoriaMetrics (:8428/write, via docker-entrypoint.sh)
Grafana ──→ (datasource Prometheus à configurer — Phase 3)
```

**Principe clé** : VM accepte le même protocole d'écriture qu'InfluxDB (line
protocol sur HTTP `/write`). Aucun changement côté Telegraf ni speedtest — on
redirige l'URL cible et ça fonctionne.

### Fichiers ajoutés/modifiés

| Fichier                              | Rôle                                                       |
| ------------------------------------ | ---------------------------------------------------------- |
| `sim/docker-compose.sim-vm-only.yml` | 3e overlay Compose : remplace InfluxDB par VM              |
| `sim/telegraf-sim-vm-only.conf`      | Telegraf config avec VM comme seul output                  |
| `sim/telegraf-vm-only.conf`          | Telegraf config pour tests d'intégration (x86 natif)       |
| `scripts/export-vm-data.sh`          | Exporte les données speedtest de VM → format InfluxDB JSON |
| `scripts/integration-test-vm.sh`     | Suite de tests d'intégration automatisée (23 tests)        |
| `Justfile`                           | Recettes `sim-vm-only-*` et `test-vm-integration`          |

---

## 2. Environnement de simulation (VM-only)

La simulation reproduit la stack RPi4 complète en ARM64 via QEMU, avec VM comme
seul backend (InfluxDB et Chronograf sont désactivés par `entrypoint: ['true']`).

### Démarrage

```bash
just sim-vm-only-up
```

Résultat validé :

- 7 containers créés (~4s)
- VM healthy confirmé par curl côté hôte (pas de healthcheck Docker — impossible sous QEMU ARM64)
- Telegraf écrit dans VM toutes les 20s
- ~756 séries actives après 1 minute

### Supervision

```bash
just sim-vm-only-status   # état containers + /health
just sim-vm-stats         # séries actives, débit d'ingestion, stockage, noms de métriques
just sim-vm-only-logs     # logs consolidés (par défaut : 50 dernières lignes)
```

`sim-vm-stats` affiche :

- **Active Time Series** : nombre de séries en cours d'ingestion
- **Ingestion Rate** : lignes/sec sur les 5 dernières minutes
- **Storage Size** : taille disque
- **Metric Names** : liste des 30 premières métriques

### Requêtes ad-hoc

```bash
just sim-vm-query 'count({__name__=~".+"})'           # nombre total de séries
just sim-vm-query 'cpu_usage_idle{cpu="cpu-total"}'    # valeur CPU idle actuelle
just sim-vm-query 'rate(vm_rows_inserted_total[5m])'   # débit d'ingestion VM interne
```

Résultat validé : retourne du JSON Prometheus standard avec `status: "success"`.

### Arrêt / nettoyage

```bash
just sim-vm-only-stop    # stop containers (conserve volumes)
just sim-vm-only-down    # stop + supprime containers (conserve volumes)
just sim-vm-only-nuke    # stop + supprime containers ET volumes (⚠️ confirmation requise)
```

---

## 3. Export et pipeline frontend

Le frontend (GitHub Pages) consomme un `data.json` au format InfluxDB. Le target
`sim-vm-only-export` produit exactement ce format à partir de l'API VM.

```bash
just sim-vm-only-export                          # export 30 jours → /tmp/sim-vm-only-data.json
just sim-vm-only-export days=7                   # seulement les 7 derniers jours
just sim-vm-only-export output=/tmp/custom.json   # chemin personnalisé
```

Résultat validé : produit un JSON avec `results[].series[].columns = ['time', 'download_bandwidth', 'upload_bandwidth', 'ping_latency']` — identique au format InfluxDB.

### Preview frontend avec données VM

```bash
just sim-vm-only-preview   # exporte + lance le serveur local sur :8080
```

Chaîne automatiquement `sim-vm-only-export` puis `preview-dev`.

---

## 4. Tests

Trois niveaux de test couvrent l'intégration VM.

### 4.1 Tests unitaires (lib.js)

```bash
just test-unit   # 94 tests, ~800ms
```

Indépendants du backend — valident les fonctions pures du frontend (LTTB,
bucketize, histogram, quality score, stats). Exécution systématique après toute
modification de `lib.js` ou `app.js`.

### 4.2 Smoke tests sim (VM backend)

```bash
# Nécessite : just sim-vm-only-up (stack active)
just sim-vm-only-test
```

Exécute `test-stack.sh --mode sim --backend vm` : vérifie que les containers
sont up, que VM répond, que les métriques attendues sont présentes, et que
l'écriture speedtest fonctionne via l'API InfluxDB-compatible.

**Dernière exécution validée** : 6/6 passed.

### 4.3 Tests d'intégration complets

```bash
just test-vm-integration              # full : pipeline + export + E2E Playwright
just test-vm-integration --skip-e2e   # sans Playwright (feedback plus rapide)
just test-vm-integration --keep       # garde les containers pour debug
```

Ce test est **autonome** — il crée son propre réseau Docker, ses propres
containers x86 natifs (pas de QEMU), et nettoie tout en fin d'exécution.

**Ce qu'il vérifie (21 assertions sans E2E, 23 avec) :**

1. **Infrastructure** — VM démarre, répond sur /health
2. **Pipeline Telegraf → VM** — métriques système arrivent (cpu, mem, disk, swap, uptime)
3. **Valeurs réalistes** — cpu_usage_idle entre 0 et 100%
4. **Écriture speedtest** — injection de 150 points simulés sur 30 jours via line protocol
5. **Export** — `export-vm-data.sh` produit du JSON InfluxDB valide avec colonnes `[time, download_bandwidth, upload_bandwidth, ping_latency]`
6. **Frontend E2E** — Playwright valide le dashboard avec des données VM-sourced (optionnel avec `--skip-e2e`)

Les tests d'intégration utilisent des containers x86 natifs pour la vitesse (pas
d'émulation QEMU). Le réseau isolé (`vm-it-net`) évite toute collision avec la
sim stack.

**Dernière exécution validée** : 21/21 passed (--skip-e2e), ~38s.

---

## 5. Contraintes QEMU identifiées

L'émulation ARM64 via QEMU introduit une contrainte critique :

| Problème                                                    | Impact                                         | Solution                                                                                        |
| ----------------------------------------------------------- | ---------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `wget`/`curl` dans containers ARM64 très lents (~30s/appel) | Docker healthcheck ne passe jamais à "healthy" | `healthcheck: disable: true` dans le compose + validation côté hôte via `curl` dans le Justfile |
| Startup plus lent qu'en natif                               | VM démarre en ~4s au lieu de <1s               | Boucle d'attente dans `sim-vm-only-up` (max 120s)                                               |

---

## 6. Ce qui reste à faire

| Étape                         | Description                                     | Statut     |
| ----------------------------- | ----------------------------------------------- | ---------- |
| Simulation VM-only            | Stack ARM64 complète, tous les flux validés     | ✅ Done    |
| Tests d'intégration           | 23 assertions, pipeline complet                 | ✅ Done    |
| Export VM → data.json         | Format InfluxDB JSON compatible frontend        | ✅ Done    |
| Grafana datasource Prometheus | Remplacer les dashboards InfluxQL par MetricsQL | ⬜ Phase 3 |
| Migration données historiques | Import des données InfluxDB existantes dans VM  | ⬜ Phase 4 |
| Déploiement RPi4              | Basculer la stack production sur VM             | ⬜ Phase 5 |
| Alertes Grafana               | Re-pointer les alertes vers la datasource VM    | ⬜ Phase 3 |

---

## 7. Recettes Just — référence rapide

### Lifecycle

| Recette                 | Description                                      |
| ----------------------- | ------------------------------------------------ |
| `just sim-vm-only-up`   | Démarre la simulation VM-only + attend /health   |
| `just sim-vm-only-stop` | Stop containers (conserve volumes)               |
| `just sim-vm-only-down` | Stop + supprime containers                       |
| `just sim-vm-only-nuke` | Supprime containers ET volumes (⚠️ confirmation) |

### Observabilité

| Recette                      | Description                                    |
| ---------------------------- | ---------------------------------------------- |
| `just sim-vm-only-status`    | État containers + santé VM                     |
| `just sim-vm-stats`          | Séries actives, ingestion, stockage, métriques |
| `just sim-vm-only-logs [N]`  | Dernières N lignes de logs (défaut: 50)        |
| `just sim-vm-query '<expr>'` | Requête MetricsQL ad-hoc                       |

### Tests

| Recette                    | Description                               |
| -------------------------- | ----------------------------------------- |
| `just test-unit`           | 94 tests unitaires lib.js (~800ms)        |
| `just sim-vm-only-test`    | Smoke tests sur la stack active           |
| `just test-vm-integration` | Intégration complète (autonome, 23 tests) |

### Frontend

| Recette                    | Description                            |
| -------------------------- | -------------------------------------- |
| `just sim-vm-only-export`  | Exporte les données VM → JSON InfluxDB |
| `just sim-vm-only-preview` | Export + preview dashboard sur :8080   |
