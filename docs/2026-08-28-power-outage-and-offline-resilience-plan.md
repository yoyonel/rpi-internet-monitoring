# Plan de Résilience : Coupures Électriques, Désynchronisation WAN & Observabilité Frontend

> **Date** : 2026-08-28  
> **Statut** : Validé — En cours d'implémentation  
> **Auteur** : Lionel ATTY / Antigravity

---

## 1. Contexte & Post-Mortem de l'Incident (Août 2026)

À la suite d'une panne de courant et de micro-coupures de courant répétées :

1. **Désynchronisation temporelle Box vs RPi** : Le Raspberry Pi 4 a redémarré rapidement (~25s) sans horloge matérielle (RTC). La Box Internet (fibre/routeur) a mis plusieurs minutes à se resynchroniser.
2. **Crash de `speedtest-cron` (Volume mount invalide)** : Au reboot, le daemon Docker a tenté de remonter un ancien chemin hôte (`sim/speedtest-loop.sh` déplacé vers `scripts/speedtest-loop.sh`). Docker a créé un répertoire `root:root` fantôme à la place, provoquant l'échec immédiat du conteneur (`exit 127`).
3. **Crash-loop de `telegraf` (Strict parsing Telegraf 1.38)** : Le bloc de sortie optionnel VictoriaMetrics avait `${VICTORIA_METRICS_URL}` non défini (`""`). Telegraf v1.38 a rejeté l'URL vide (`unsupported scheme [""]: ""`) et s'est arrêté en boucle. Zéro métrique hôte injectée $\rightarrow$ alertes Grafana `%!f(<nil>)`.
4. **"Trou noir" dans InfluxDB** : En cas de panne WAN, le conteneur speedtest sortait en code 1 sans rien écrire dans InfluxDB (aucune mesure `0 Mb/s` ou `status=outage`).
5. **Illusion de synchronisation sur GitHub Pages** : Le timer `publish-gh-pages.timer` a continué à tourner toutes les 10 min et à pousser une page web avec horodatage "Mise à jour : OK", masquant l'arrêt total de la collecte.

---

## 2. Anomalie Observabilité Frontend (Base de Référence Temporelle & Fraîcheur)

### 2.1 Les 4 failles identifiées dans le Frontend

```
[Date réelle : 28/08 07:00]
         │
         ├── syncDot lit `time[datetime]` (génération template HTML = 28/08 06:50)
         │   └── Affiche : Point VERT ("Synchronisation OK < 10 min") ❌ FAUX POSITIF !
         │
         ├── Données réelles dans `data.json` : Dernier point = 23/08 20:23
         │   └── `range.dataEnd = 23/08 20:23`
         │
         ├── Bouton "Auj." (Today) :
         │   └── `start = 28/08 00:00` (minuit du jour réel)
         │   └── `end = dataEnd = 23/08 20:23`
         │   └── `start > end` (intervalle inversé !) ➔ "Aucune donnée sur cette période" ❌
         │
         └── Boutons de presets ("6h", "12h", "24h") :
             └── `end = range.dataEnd` (ancré dans le passé au 23/08)
             └── `start = 23/08 14:23`
             └── Affiche les courbes du 23/08 sans avertir l'utilisateur ❌
```

### 2.2 Correctifs Frontend requis

1. **Indicateur de fraîcheur basé sur `max(data.ts)`** :
   - Ne plus baser le point `syncDot` sur l'heure de génération du HTML, mais sur l'écart entre `Date.now()` et le timestamp du dernier point speedtest (`data.ts[data.LEN - 1]`).
   - Si `Date.now() - lastDataTimestamp > 30 min` $\rightarrow$ Point ROUGE clignotant + Bannière explicite "Données obsolètes (dernière mesure il y a X jours / heures)".
2. **Ancrage temporel du mode Live sur `Date.now()`** :
   - En mode `isLive`, `range.end` doit valoir `Date.now()`, et non `range.dataEnd`.
   - Ainsi, un preset `6h` affiche bien les 6 dernières heures réelles (qui seront vides en cas de coupure, montrant clairement le manque de données récent au lieu de masquer la panne).
3. **Résolution du bug "Auj." (Today)** :
   - `start = minuit local`, `end = Date.now()`. L'intervalle reste toujours valide (`start <= end`).

---

## 3. Plan d'Implémentation Détaillé par Phase

```mermaid
flowchart TD
    subgraph Phase 1: Frontend Observability
        F1[Ancrer isLive sur Date.now] --> F2[Calculer fraîcheur sur data.ts]
        F2 --> F3[Bannière Alerte Données Obsolètes]
    end

    subgraph Phase 2: WAN Outage Logging
        W1[Catch échec Speedtest / DNS] --> W2[Écriture InfluxDB status=outage / 0 Mbps]
        W2 --> W3[Rendu graphique des coupures]
    end

    subgraph Phase 3: Docker & Config Hardening
        D1[Intégrer speedtest-loop.sh dans Dockerfile] --> D2[Supprimer bind-mounts fragiles]
        D2 --> D3[Sécuriser Telegraf conf fallback]
        D3 --> D4[Healthcheck speedtest-cron]
    end

    subgraph Phase 4: Boot Resilience
        B1[Attente NTP / Network au boot] --> B2[Monitoring-boot-check service]
        B2 --> B3[fsck.repair=yes cmdline]
    end

    Phase 1 --> Phase 2 --> Phase 3 --> Phase 4
```

---

### Phase 1 : Correctifs Frontend (Base Temporelle & Détection Décrochage)

- [ ] **`gh-pages/state.js`** :
  - Définir `range.end = Date.now()` en mode `isLive`.
  - Exposer `lastTimestamp = data.ts[data.LEN - 1]`.
- [ ] **`gh-pages/time-controls.js`** :
  - `setRange(h)` : calculer `start = Date.now() - h * HOUR`, `end = Date.now()`.
  - `setToday()` : calculer `start = minuit`, `end = Date.now()`.
- [ ] **`gh-pages/sync-status.js`** :
  - Comparer `Date.now()` avec le timestamp du dernier échantillon InfluxDB.
  - Afficher un badge / avertissement si l'échantillon a plus de 20 minutes.
- [ ] **Tests E2E Playwright** :
  - Ajouter un test vérifiant le comportement de la page en présence d'un jeu de données figé dans le passé.

---

### Phase 2 : Enregistrement Explicite des Pannes WAN (Data Pipeline)

- [ ] **`docker-entrypoint.sh`** :
  - Tester la connectivité WAN / DNS avant d'exécuter `speedtest`.
  - En cas d'échec (DNS KO, Timeout Ookla, Routeur injoignable) :
    - Logger explicitement un point d'arrêt dans InfluxDB :
      ```lineprotocol
      speedtest,result_id=outage,status=down download_bandwidth=0,upload_bandwidth=0,ping_latency=-1
      ```
  - Permet aux graphiques d'afficher un débit à 0 et une rupture franche plutôt qu'un trou silencieux.
- [ ] **`gh-pages/charts.js`** :
  - Gérer les points `download_bandwidth = 0` / `ping_latency = -1` avec un style adapté (point rouge / zone hachurée d'indisponibilité).

---

### Phase 3 : Durcissement Docker & Configuration

- [ ] **`Dockerfile`** :
  - Copier `scripts/speedtest-loop.sh` dans `/usr/local/bin/speedtest-loop.sh` lors du build de l'image.
  - Supprimer le volume bind mount `./scripts/speedtest-loop.sh` dans `docker-compose.yml`.
- [ ] **`telegraf/telegraf.conf`** :
  - Verrouiller la configuration pour n'avoir aucun bloc de sortie invalide par défaut.
- [ ] **Auto-healing du conteneur `speedtest-cron`** :
  - Ajouter un `HEALTHCHECK` dans Dockerfile / Compose vérifiant la date de la dernière exécution (`/tmp/last_run`).

---

### Phase 4 : Résilience au Boot & Horloge Système

- [ ] **Synchronisation Horloge / NTP** :
  - Vérifier que `systemd-timesyncd` est synchronisé avant d'effectuer des requêtes distantes avec validation TLS.
- [ ] **Service Systemd `monitoring-boot-check`** :
  - Créer un service systemd `monitoring-boot-check.service` exécuté après le démarrage du réseau :
    - Vérifie l'état de la stack (`docker compose ps`).
    - Force un `docker compose up -d` si des conteneurs sont `Exited`.
    - Déclenche une publication initiale une fois la connexion WAN vérifiée.
- [ ] **Protection Système de Fichiers** :
  - Documenter / valider l'option `fsck.repair=yes` dans `/boot/cmdline.txt` pour les Raspberry Pi sous Raspberry Pi OS.

---

## 4. Matrice de Suivi & Validation

| Phase       | Composant | Tâche                                    | Validation                                                                      |
| :---------- | :-------- | :--------------------------------------- | :------------------------------------------------------------------------------ |
| **Phase 1** | Frontend  | Ancrage `isLive` sur `Date.now()`        | Presets 6h/24h affichent la période réelle courante.                            |
| **Phase 1** | Frontend  | `syncDot` basé sur `lastTimestamp`       | Point rouge + bannière d'alerte si pas de données > 30 min.                     |
| **Phase 2** | Pipeline  | Écriture `status=down` / `0 Mb/s`        | InfluxDB enregistre la coupure lors d'une déconnexion câble WAN.                |
| **Phase 3** | Docker    | `speedtest-loop.sh` intégré dans l'image | `docker compose up` démarre sans aucun bind-mount de script.                    |
| **Phase 3** | Docker    | Healthcheck `speedtest-cron`             | Statut `healthy` visible dans `docker ps`.                                      |
| **Phase 4** | OS / Boot | `monitoring-boot-check.service`          | Reboot simulé $\rightarrow$ la stack remonte automatiquement sans intervention. |
