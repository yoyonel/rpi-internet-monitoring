# Plan de rollback — Migration VictoriaMetrics

> **Contexte** : À chaque phase de la migration InfluxDB → VictoriaMetrics, un retour arrière doit être possible en < 5 minutes. Ce document décrit les procédures de rollback par phase.

---

## Critères de déclenchement du rollback

| Condition                          | Seuil                 |
| ---------------------------------- | --------------------- |
| VM crash-loop                      | > 3 restarts en 1h    |
| Données manquantes                 | > 10 min sans point   |
| RAM VictoriaMetrics                | > 300 Mo              |
| Dashboards Grafana cassés          | Panneaux vides/erreur |
| GitHub Pages ne se met plus à jour | > 30 min de retard    |
| Alertes non fonctionnelles         | Test manuel échoué    |

---

## Rollback par phase

### Phase 1 — Dual-stack local

**Risque** : Faible. InfluxDB continue de fonctionner normalement.

**Procédure** :

```bash
# Arrêter uniquement VictoriaMetrics
docker compose stop victoriametrics

# Optionnel : retirer le service du compose
# (ou simplement ne pas démarrer le profile vm)
docker compose --profile influxdb up -d
```

**Temps** : < 1 minute
**Perte de données** : Aucune (InfluxDB reçoit toujours les écritures)

---

### Phase 2 — Tests & validation

**Risque** : Nul. Les tests n'impactent pas la production.

**Procédure** : Aucune action requise — les tests sont isolés dans `sim/` et CI.

---

### Phase 3 — Migration Grafana & scripts

**Risque** : Moyen. Les dashboards et scripts sont modifiés.

**Procédure** :

```bash
# Les dashboards InfluxDB originaux sont conservés (non supprimés)
# Restaurer le datasource par défaut :
# grafana/provisioning/datasources/influxdb.yml → isDefault: true

# Restaurer publish-gh-pages.sh :
git checkout origin/master -- scripts/publish-gh-pages.sh

# Redémarrer Grafana pour recharger le provisioning
docker compose restart grafana
```

**Temps** : < 3 minutes
**Perte de données** : Aucune (les deux datasources coexistent)

---

### Phase 4 — Données historiques

**Risque** : Faible. La migration est additive (copie, pas déplacement).

**Procédure** : Aucune action requise. Les données InfluxDB originales sont intactes.

---

### Phase 5 — Bascule production

**Risque** : Élevé. La lecture passe sur VM.

**Procédure** :

```bash
# 1. Reconfigurer en mode InfluxDB-only
export TSDB_BACKEND=influxdb

# 2. Restart Telegraf (coupe le dual-write, écrit uniquement dans InfluxDB)
docker compose restart telegraf

# 3. Restart speedtest-cron (idem)
docker compose restart speedtest-cron

# 4. Restaurer publish-gh-pages.sh en mode InfluxDB
# (le script supporte TSDB_BACKEND=influxdb)

# 5. Restaurer les dashboards Grafana InfluxDB comme défaut
docker compose restart grafana

# 6. Arrêter VM
docker compose stop victoriametrics
```

**Temps** : < 5 minutes
**Perte de données** : Les points écrits uniquement dans VM (si mode vm-only) sont perdus. En mode dual, aucune perte.

---

### Phase 6 — Nettoyage (point de non-retour)

**Risque** : Irréversible après suppression des volumes InfluxDB.

**Prérequis avant d'entrer en Phase 6** :

- [ ] 30 jours de fonctionnement stable sur VM
- [ ] Aucun rollback déclenché
- [ ] Backup final InfluxDB archivé off-site
- [ ] Validation écrite de l'utilisateur

**Rollback** : Restaurer depuis le backup off-site.

```bash
# Restaurer un backup InfluxDB (si les volumes ont été supprimés)
docker run --rm -v influxdb-data:/var/lib/influxdb \
  influxdb:1.8.10 influxd restore -portable /backup/
```

**Temps** : 10-30 minutes (selon taille du backup)

---

## Script de rollback automatisé

Voir `scripts/vm-rollback.sh` (à créer lors de l'implémentation) :

```bash
#!/usr/bin/env bash
# scripts/vm-rollback.sh — Rollback VictoriaMetrics → InfluxDB
set -euo pipefail

echo "⚠️  Rollback VictoriaMetrics → InfluxDB"
echo "    Cela va :"
echo "    1. Arrêter VictoriaMetrics"
echo "    2. Reconfigurer Telegraf en mode InfluxDB-only"
echo "    3. Redémarrer la stack"
echo ""
read -rp "Confirmer ? [y/N] " confirm
[[ "$confirm" == "y" ]] || exit 1

# Stop VM
docker compose stop victoriametrics

# Set backend to influxdb
export TSDB_BACKEND=influxdb

# Restart services that write data
docker compose restart telegraf speedtest-cron

# Restart Grafana to reload datasources
docker compose restart grafana

# Verify
echo "Vérification..."
sleep 10
docker compose ps --format "table {{.Name}}\t{{.Status}}"

echo ""
echo "✅ Rollback terminé. InfluxDB est le backend actif."
echo "   Vérifier : http://localhost:8888 (Chronograf)"
echo "   Vérifier : http://localhost:3000 (Grafana)"
```

---

## Matrice de risque résumée

| Phase | Réversibilité | Temps rollback   | Perte données     |
| ----- | ------------- | ---------------- | ----------------- |
| 1     | Totale        | < 1 min          | Aucune            |
| 2     | Totale        | 0 (rien à faire) | Aucune            |
| 3     | Totale        | < 3 min          | Aucune            |
| 4     | Totale        | 0 (rien à faire) | Aucune            |
| 5     | Totale (dual) | < 5 min          | Aucune            |
| 6     | Partielle     | 10-30 min        | Possible (backup) |

---

## Checklist pré-bascule (Phase 5)

- [ ] Backup InfluxDB complet réalisé (`just backup`)
- [ ] Backup testé en restauration (`just sim-test` après restore)
- [ ] Dual-write validé pendant 24h (données dans les deux DB)
- [ ] Dashboards VM testés et comparés visuellement
- [ ] publish-gh-pages.sh testé avec `TSDB_BACKEND=vm`
- [ ] E2E Playwright passent avec données VM
- [ ] Plan de rollback relu et compris
- [ ] Créneau de maintenance choisi (faible trafic)
