# rpi-internet-monitoring — Copilot Instructions

## Workflow obligatoire pour tout changement

### Checklist avant de rendre la main à l'utilisateur

Chaque modification DOIT passer par TOUTES ces étapes, dans l'ordre. Ne JAMAIS s'arrêter à mi-chemin ni attendre qu'on me rappelle une étape.

1. **Justfile** — Si du code testable ou exécutable est ajouté/modifié, vérifier qu'une recette Just existe. Sinon, la créer.
2. **Tests unitaires** — `just test-unit` (39+ tests sur `lib.js`). Lancer systématiquement après toute modification de `gh-pages/lib.js` ou `gh-pages/app.js`.
3. **Preview** — `just preview-dev` pour démarrer le serveur local.
4. **Tests E2E** — `just test-e2e` (12+ tests Playwright). Lancer PENDANT que le preview tourne, DANS LA MÊME SESSION. Ne jamais lancer un preview sans enchaîner les E2E.
5. **CI** — Vérifier que le workflow `lint.yml` (ou un autre) couvre le nouveau code. Ajouter un step si nécessaire.
6. **Documentation** — Mettre à jour le `README.md` (sections Testing, Architecture, recettes Just) si le changement est visible par l'utilisateur.
7. **Arrêter le preview** — Tuer le serveur une fois les tests finis.

### Séparation des commits (SoC)

- `refactor:` pour l'extraction/restructuration de code
- `test:` pour les tests unitaires et E2E
- `ci:` pour les workflows GitHub Actions
- `docs:` pour README et documentation
- `chore:` pour Justfile, package.json, configuration

Ne JAMAIS mélanger des fichiers de natures différentes dans un même commit.

## Architecture frontend (gh-pages/)

- `gh-pages/lib.js` — Fonctions pures (LTTB, bucketize, histogram, quality score, stats, bsearch, filterRange). ES module. Testable avec Node.js.
- `gh-pages/app.js` — Orchestration DOM (Chart.js, rendu, événements). Importe `lib.js`.
- `gh-pages/index.template.html` — `<script type="module" src="app.js">`.

### Pipeline de build

4 endroits copient les assets frontend — TOUS doivent être mis à jour si un fichier est ajouté/renommé dans `gh-pages/` :

1. `scripts/publish-gh-pages.sh`
2. `scripts/publish-template.sh`
3. `scripts/preview-dev.sh`
4. `.github/workflows/deploy-gh-pages.yml`

Terser doit utiliser `--module` pour les fichiers ES module (`app.js`, `lib.js`).

## Recettes Just disponibles

### Testing

- `just test-unit` — Tests unitaires lib.js (Node.js, ~300ms)
- `just test-e2e` — Tests E2E Playwright (nécessite preview actif)
- `just test` — Régression stack complète (nécessite RPi)
- `just sim-test` — Smoke tests stack sim
- `just lint` — Linting tous sources
- `just fmt` — Auto-formatage

### Preview

- `just preview-dev [port]` — Preview avec données live GitHub Pages
- `just preview [N]` — Preview avec données InfluxDB locales

## Règles CI/CD — scripts/ci/

### Pas de logique métier inline dans les workflows

Les fichiers `.github/workflows/*.yml` sont des **orchestrateurs**, pas des scripts. Toute logique non-triviale DOIT être dans un script externe sous `scripts/ci/`.

**Règle des 5 lignes** : si un bloc `run:` dépasse 5 lignes OU contient des boucles, conditions, ou appels API complexes → extraire dans `scripts/ci/<nom>.sh` (ou `.py`).

**Autorisé inline** (≤5 lignes, sans logique) :

- `npm ci && npx playwright install --with-deps chromium`
- `docker network create grafana-ci`
- `docker rm -f grafana 2>/dev/null || true`
- Appel simple : `bash scripts/ci/start-influxdb.sh --network grafana-ci`

**Interdit inline** :

- Boucles `for`/`while` (health checks, data seeding, retries)
- Scripts Python embarqués dans des `run:` blocks
- Logique conditionnelle complexe (extraction de PR number, badge generation)
- Construction de payloads JSON/HTTP
- Toute logique métier testable

### Convention de nommage

- `scripts/ci/start-<service>.sh` — Démarrage de containers Docker
- `scripts/ci/seed-<context>-data.sh` — Injection de données de test
- `scripts/ci/<workflow>-<action>.sh` — Action spécifique à un workflow
- `scripts/ci/<utility>.py` — Utilitaires Python

### Paramétrage

- Les scripts CI acceptent des arguments CLI (`--network`, `--influx-listen-addr`) plutôt que de hardcoder des valeurs
- Les credentials passent par variables d'environnement (`INFLUXDB_ADMIN_USER`, etc.)
- `$GITHUB_OUTPUT` et `$GITHUB_ENV` sont utilisés via `>>"${GITHUB_ENV:-/dev/null}"` pour être testables localement

### Lint

- `scripts/ci/*.sh` est couvert par `shellcheck` et `shfmt` dans `just lint`
- `scripts/ci/*.py` est couvert par `ruff` dans `just lint`
