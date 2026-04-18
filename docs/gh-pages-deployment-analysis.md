# GitHub Pages — Deployment Analysis

## Constat : deux acteurs écrivent sur `gh-pages`

|                        | **RPI (systemd timer)**                                                    | **CI (GitHub Actions)**                                                                         |
| ---------------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| **Script**             | `scripts/publish-gh-pages.sh`                                              | `.github/workflows/deploy-gh-pages.yml`                                                         |
| **Trigger**            | `publish-gh-pages.timer` → toutes les 10 min                               | Push sur `master` (paths: `gh-pages/**`, `render-template.py`, `extract-live-data.py`) + manual |
| **Source des données** | InfluxDB local (Docker) + Grafana API locale (alertes)                     | `curl` du site live → `extract-live-data.py` pour re-extraire les données                       |
| **Template**           | `gh-pages/index.template.html`                                             | `gh-pages/index.template.html`                                                                  |
| **Méthode push**       | `git push --force-with-lease` vers branche `gh-pages`                      | `upload-pages-artifact` + `deploy-pages` (GitHub Actions Pages API)                             |
| **Contenu**            | `index.html, style.css, app.js, data.json, alerts.json, fonts/, .nojekyll` | Idem, via artifact → Pages API                                                                  |

## Conflit de déploiement

```
RPI (toutes les 10 min)                CI (à chaque push master)
        │                                       │
        ▼                                       ▼
  git push --force-with-lease          upload-pages-artifact
  → branche gh-pages                   → GitHub Pages API (Actions)
        │                                       │
        └───────── CONFLIT ─────────────────────┘
                      │
              GitHub Pages sert QUOI ?
              → Config repo = "Deploy from branch: gh-pages"
              → Le RPI gagne (branche)
              → Le workflow CI écrit dans le vide (artifact API)
```

**Le workflow CI ne fait rien d'utile en prod.** Il upload un artifact Pages, mais le repo est configuré en mode legacy (branche `gh-pages`). Donc :

- Le RPI push `--force-with-lease` sur `gh-pages` toutes les 10 min → **c'est lui qui alimente le site**
- Le CI upload un artifact que personne ne sert
- Le CI fetch les données depuis le site live (que le RPI a mis à jour) pour les re-injecter dans un artifact inutile

## Problème secondaire : `extract-live-data.py`

Le workflow CI utilise `extract-live-data.py` pour récupérer les données depuis le site live. Depuis la PR #11, les données sont dans `data.json`/`alerts.json` (fichiers séparés) au lieu d'être inline dans le HTML. Le script actuel (sur master) cherche `RAW_DATA = {...}` dans le HTML → il ne trouve plus rien.

## Questions ouvertes

1. **Quel est le rôle voulu du workflow CI ?**

   - Option A : rebuild du template seulement (quand `gh-pages/**` change sur master) → ne touche pas aux données, re-render HTML/CSS/JS avec les données existantes sur la branche `gh-pages`
   - Option B : déploiement complet indépendant → doit passer en mode `git push` sur la branche (comme le RPI), mais race condition avec le timer 10 min

2. **Le CI doit-il utiliser des données locales ou distantes ?**

   - Le RPI a les données fraîches (InfluxDB + Grafana)
   - Le CI n'a pas accès à InfluxDB → il dépend forcément de données existantes (site live ou branche gh-pages)
   - Faut-il que le CI récupère `data.json`/`alerts.json` depuis la branche `gh-pages` directement (git checkout) au lieu de curl le site ?

3. **Faut-il aligner la méthode de déploiement ?**
   - Le RPI utilise `git push` → cohérent avec la config legacy du repo
   - Le CI utilise Actions Pages API → incohérent avec la config legacy
   - → Le CI devrait probablement utiliser `git push` aussi, ou on change la config repo en mode Actions Pages (mais alors le RPI ne peut plus push)
