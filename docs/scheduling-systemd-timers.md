# Scheduling : de crontab à systemd timers

> **Statut** : implémenté (unit files + Justfile), **pas encore déployé sur le RPi**.
> À reprendre dès que l'accès au Raspberry Pi est rétabli.

---

## Table des matières

1. [Contexte & historique](#contexte--historique)
2. [Pourquoi quitter cron](#pourquoi-quitter-cron)
3. [Pourquoi systemd timers](#pourquoi-systemd-timers)
4. [Architecture](#architecture)
5. [Référence des unit files](#référence-des-unit-files)
   - [speedtest.service](#speedtestservice)
   - [speedtest.timer](#speedtesttimer)
   - [publish-gh-pages.service](#publish-gh-pagesservice)
   - [publish-gh-pages.timer](#publish-gh-pagestimer)
6. [Recettes Justfile](#recettes-justfile)
7. [Checklist de migration RPi](#checklist-de-migration-rpi)
8. [Commandes de diagnostic](#commandes-de-diagnostic)
9. [Troubleshooting](#troubleshooting)
10. [Décisions & alternatives envisagées](#décisions--alternatives-envisagées)

---

## Contexte & historique

### Situation initiale (2022)

Le projet a été mis en place en novembre 2022 sur un Raspberry Pi 4 sous Debian 11 (bullseye).
La planification reposait entièrement sur **crontab user** :

```
# crontab -l (sur le RPi, utilisateur latty)
*/10 * * * * /usr/bin/docker run --rm --network speedtest docker.local/speedtest:buster-slim
*/10 * * * * cd /home/latty/rpi-internet-monitoring && just publish >/dev/null 2>&1
```

Deux tâches, toutes les 10 minutes :

1. **Speedtest** : lance un conteneur Docker qui exécute le test Ookla et écrit dans InfluxDB
2. **Publish GH Pages** : exporte les données InfluxDB, génère une page HTML statique, et push vers GitHub Pages

### Évolution (avril 2026)

La stack Docker a évolué (Grafana 12.4.3, Telegraf 1.38.2, image speedtest bookworm, etc.) mais
le scheduling est resté sur crontab. Le RPi n'étant pas accessible pendant le travail de redesign,
la décision a été prise de préparer la migration vers **systemd user timers** en amont, avec des
fichiers versionnés dans le repo et une installation automatisée via Justfile.

---

## Pourquoi quitter cron

| Problème                        | Détail                                                                                                                                                                                                             |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Pas versionné**               | Le crontab vit en dehors du repo. Aucune trace dans git, aucun review possible. Si le RPi est réinstallé, il faut se souvenir des entrées exactes.                                                                 |
| **Pas de logs structurés**      | cron écrit dans syslog (`/var/log/syslog`) sans séparation par job. Filtrer les erreurs d'un job spécifique demande du `grep` manuel. La redirection `>/dev/null 2>&1` masque les erreurs silencieusement.         |
| **Pas de gestion des overlaps** | Si un speedtest prend plus de 10 minutes (réseau lent, API timeout), cron lance quand même le suivant. Deux conteneurs speedtest en parallèle peuvent produire des données corrompues ou des conflits réseau.      |
| **Pas de rattrapage**           | Si le RPi est éteint ou reboot pendant un slot cron, l'exécution est simplement perdue. Aucun mécanisme de catch-up.                                                                                               |
| **Pas de random delay**         | Toutes les 10 min exactement. Si d'autres tâches sont calées sur le même slot, elles se disputent les ressources en même temps.                                                                                    |
| **Pas de timeout**              | Si `docker compose run` hang (daemon Docker bloqué, réseau down), le process reste orphelin indéfiniment.                                                                                                          |
| **Environnement minimal**       | cron exécute dans un environnement PATH minimal. Les commandes comme `just` ou `docker compose` (v2) ne sont pas toujours dans le PATH de cron, ce qui force des chemins absolus et des hacks `source ~/.profile`. |

---

## Pourquoi systemd timers

| Avantage                     | Détail                                                                                                               |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| **Infra as code**            | Les unit files vivent dans `systemd/` dans le repo. Versionnés, reviewables, reproductibles.                         |
| **Logs natifs**              | `journalctl --user -u speedtest` donne les logs filtrés par service, avec timestamps, exit codes, durée d'exécution. |
| **Anti-overlap**             | `Type=oneshot` + `ExecCondition` : le timer ne lance pas une nouvelle instance si la précédente tourne encore.       |
| **Persistent**               | `Persistent=true` : si le RPi était éteint au moment du slot, systemd rattrape l'exécution dès le redémarrage.       |
| **RandomizedDelay**          | Étale les exécutions pour éviter les pics de charge simultanés.                                                      |
| **Timeout**                  | `TimeoutStartSec` tue le process s'il dépasse la durée autorisée.                                                    |
| **User-level**               | `systemctl --user` : pas besoin de root, pas de sudoers, pas de fichiers dans `/etc/systemd/`.                       |
| **Intégration systemd**      | `systemctl status`, `systemctl is-active`, dépendances, ordonnancement — tout l'écosystème systemd est disponible.   |
| **Installation automatisée** | `just install-timers` copie les fichiers, adapte le `WorkingDirectory`, reload, enable et start en une commande.     |

---

## Architecture

```
Repo (versionné)                       RPi (~/.config/systemd/user/)
─────────────────                       ─────────────────────────────

systemd/
├── speedtest.service          ──cp──▶  speedtest.service
├── speedtest.timer            ──cp──▶  speedtest.timer
├── publish-gh-pages.service   ──cp──▶  publish-gh-pages.service
└── publish-gh-pages.timer     ──cp──▶  publish-gh-pages.timer

Justfile
├── install-timers       → copie + sed WorkingDirectory + daemon-reload + enable --now
├── uninstall-timers     → disable --now + rm + daemon-reload
└── timer-status         → list-timers + journalctl
```

### Flux d'exécution

```
systemd timer manager
    │
    ├── speedtest.timer (OnCalendar=*:0/10, RandomizedDelaySec=30)
    │       │
    │       └── speedtest.service (oneshot)
    │               │
    │               ├── ExecCondition: vérifie qu'aucun conteneur speedtest ne tourne
    │               └── ExecStart: docker compose run --rm speedtest
    │                       │
    │                       └── Conteneur speedtest → Ookla CLI → InfluxDB
    │
    └── publish-gh-pages.timer (OnCalendar=*:0/10, RandomizedDelaySec=60)
            │
            └── publish-gh-pages.service (oneshot)
                    │
                    └── ExecStart: bash scripts/publish-gh-pages.sh 30
                            │
                            ├── Requête InfluxDB (30j de données)
                            ├── Export alertes Grafana
                            ├── Injection dans le template HTML
                            └── git push vers gh-pages
```

---

## Référence des unit files

### speedtest.service

**Chemin repo** : `systemd/speedtest.service`
**Chemin installé** : `~/.config/systemd/user/speedtest.service`

```ini
[Unit]
Description=Run internet speedtest and store result in InfluxDB

[Service]
Type=oneshot
WorkingDirectory=%h/rpi-internet-monitoring
ExecStart=/usr/bin/docker compose run --rm speedtest
TimeoutStartSec=300
ExecCondition=/bin/sh -c '! docker ps --format "{{.Names}}" | grep -q speedtest'
```

| Directive                                     | Rôle                                                                                                                                                                                                                                                                                                  |
| --------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Type=oneshot`                                | Le service exécute une commande et se termine. Pas de daemon.                                                                                                                                                                                                                                         |
| `WorkingDirectory=%h/rpi-internet-monitoring` | Valeur par défaut, **remplacée par le chemin réel** lors de `just install-timers` via `sed`. `%h` = `$HOME` de l'utilisateur.                                                                                                                                                                         |
| `ExecStart`                                   | Lance le conteneur speedtest (build via Dockerfile, réseau Docker, écrit dans InfluxDB). `--rm` supprime le conteneur après exécution.                                                                                                                                                                |
| `TimeoutStartSec=300`                         | 5 minutes max. Un speedtest normal prend 30-60s, mais sur réseau lent ça peut monter. Au-delà, systemd tue le process (SIGTERM puis SIGKILL).                                                                                                                                                         |
| `ExecCondition`                               | **Guard anti-overlap**. Vérifie via `docker ps` qu'aucun conteneur nommé "speedtest" ne tourne. Si la condition échoue (exit ≠ 0), le service est skipped sans erreur. Protège contre : timer qui fire pendant qu'un ancien run est encore en cours, ou run manuel via `just speedtest` en parallèle. |

### speedtest.timer

**Chemin repo** : `systemd/speedtest.timer`

```ini
[Unit]
Description=Speedtest every 10 minutes

[Timer]
OnCalendar=*:0/10
RandomizedDelaySec=30
Persistent=true

[Install]
WantedBy=timers.target
```

| Directive                | Rôle                                                                                                                                                      |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `OnCalendar=*:0/10`      | Toutes les 10 minutes (`:00`, `:10`, `:20`, `:30`, `:40`, `:50`). Équivalent de `*/10 * * * *` en cron.                                                   |
| `RandomizedDelaySec=30`  | Ajoute un délai aléatoire entre 0 et 30 secondes à chaque déclenchement. Évite que speedtest et publish s'exécutent exactement au même moment.            |
| `Persistent=true`        | Si le RPi était éteint au moment d'un slot, l'exécution est rattrapée au prochain démarrage. Critique pour un appareil qui peut être débranché/rebranché. |
| `WantedBy=timers.target` | Le timer démarre automatiquement au boot (après `enable`).                                                                                                |

### publish-gh-pages.service

**Chemin repo** : `systemd/publish-gh-pages.service`

```ini
[Unit]
Description=Publish monitoring page to GitHub Pages

[Service]
Type=oneshot
WorkingDirectory=%h/rpi-internet-monitoring
ExecStart=/usr/bin/bash scripts/publish-gh-pages.sh 30
TimeoutStartSec=120
Environment=HOME=%h
```

| Directive             | Rôle                                                                                                                                                                                                           |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ExecStart`           | Exécute le script de publication avec 30 jours d'historique. Le script : exporte les données InfluxDB en JSON, récupère les alertes Grafana, injecte dans le template HTML, et push sur la branche `gh-pages`. |
| `TimeoutStartSec=120` | 2 minutes max. Le script est principalement I/O (requête InfluxDB locale + git push). 2 min est large.                                                                                                         |
| `Environment=HOME=%h` | Explicite `$HOME` pour le script. Nécessaire car certaines commandes (git, ssh-agent) en dépendent et l'environnement systemd user est plus restreint que le shell interactif.                                 |

**Note** : pas de `ExecCondition` anti-overlap ici. Le script `publish-gh-pages.sh` est idempotent (il régénère et écrase la page à chaque fois), donc deux exécutions simultanées ne posent pas de problème fonctionnel (au pire un double git push, qui est un no-op si le contenu est identique).

### publish-gh-pages.timer

**Chemin repo** : `systemd/publish-gh-pages.timer`

```ini
[Unit]
Description=Publish GitHub Pages every 10 minutes

[Timer]
OnCalendar=*:0/10
RandomizedDelaySec=60
Persistent=true

[Install]
WantedBy=timers.target
```

| Directive               | Rôle                                                                                                                                                                                                                                                                                         |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `RandomizedDelaySec=60` | Délai aléatoire plus large (0-60s) que le speedtest (0-30s). Objectif : la publication se fait _après_ le speedtest dans la majorité des cas, pour inclure le résultat le plus récent. Ce n'est pas garanti (pas de dépendance explicite `After=`), mais statistiquement ça fonctionne bien. |

---

## Recettes Justfile

### `just install-timers`

Installe les 4 unit files dans `~/.config/systemd/user/`, patche le `WorkingDirectory` avec le
chemin réel du projet (via `sed`), reload le daemon systemd, et active+démarre les deux timers.

```bash
just install-timers
```

Output attendu :

```
  → /home/latty/.config/systemd/user/speedtest.service
  → /home/latty/.config/systemd/user/speedtest.timer
  → /home/latty/.config/systemd/user/publish-gh-pages.service
  → /home/latty/.config/systemd/user/publish-gh-pages.timer

✅ Timers installed and started:
NEXT                         LEFT     LAST PASSED UNIT                     ACTIVATES
Thu 2026-04-16 15:30:22 CEST 8min left -   -      speedtest.timer          speedtest.service
Thu 2026-04-16 15:30:45 CEST 8min left -   -      publish-gh-pages.timer   publish-gh-pages.service
```

**Ce que fait la recette :**

1. `mkdir -p ~/.config/systemd/user/`
2. Copie les 4 fichiers de `systemd/` vers `~/.config/systemd/user/`
3. `sed -i` remplace `WorkingDirectory=...` par le chemin réel du projet (`justfile_directory()`)
4. `systemctl --user daemon-reload`
5. `systemctl --user enable --now speedtest.timer publish-gh-pages.timer`

### `just uninstall-timers`

Désactive et stoppe les timers, supprime les unit files, reload le daemon.

```bash
just uninstall-timers
```

### `just timer-status`

Affiche l'état des timers et les 5 derniers logs de chaque service.

```bash
just timer-status
```

Output :

```
── Timers ──
NEXT                         LEFT     LAST                         PASSED  UNIT                     ACTIVATES
Thu 2026-04-16 15:40:12 CEST 3min     Thu 2026-04-16 15:30:22 CEST 6min   speedtest.timer          speedtest.service
Thu 2026-04-16 15:40:45 CEST 4min     Thu 2026-04-16 15:30:45 CEST 6min   publish-gh-pages.timer   publish-gh-pages.service

── Recent speedtest runs ──
Apr 16 15:30:22 raspberrypi speedtest[12345]: {"results":[...]}
Apr 16 15:20:08 raspberrypi speedtest[12300]: {"results":[...]}

── Recent publish runs ──
Apr 16 15:30:45 raspberrypi publish-gh-pages[12400]: → 4318 data points exported
Apr 16 15:20:33 raspberrypi publish-gh-pages[12350]: → 4317 data points exported
```

---

## Checklist de migration RPi

> **À exécuter quand l'accès au Raspberry Pi est rétabli.**

### Pré-requis

- [ ] SSH vers le RPi fonctionnel (`ssh latty@192.168.1.24`)
- [ ] Le repo est à jour sur le RPi (`git pull` ou `git fetch && git checkout feat/gh-pages-redesign`)
- [ ] Docker fonctionne (`docker ps`)
- [ ] `just` est installé (`just --version`)
- [ ] `lingering` systemd activé pour l'utilisateur (voir ci-dessous)

### Étapes

```bash
# 1. Se connecter au RPi
ssh latty@192.168.1.24

# 2. Aller dans le projet
cd ~/rpi-internet-monitoring   # ou ~/Prog/rpi-internet-monitoring selon install

# 3. Mettre à jour le code
git fetch origin
git checkout feat/gh-pages-redesign   # ou master si déjà mergé
git pull

# 4. Vérifier la stack Docker
just status
just check

# 5. Activer le lingering systemd (IMPORTANT, une seule fois)
#    Sans ça, les timers user sont stoppés quand la session SSH se ferme.
loginctl enable-linger latty

# 6. Supprimer l'ancien crontab
crontab -l                    # noter les entrées actuelles (backup)
crontab -e                    # supprimer les lignes speedtest et publish
# OU
crontab -r                    # si le crontab ne contient QUE ces deux entrées

# 7. Installer les timers systemd
just install-timers

# 8. Vérifier que les timers tournent
just timer-status

# 9. Attendre 10-15 minutes, puis vérifier les logs
just timer-status
# Vérifier que speedtest.service et publish-gh-pages.service ont des entrées récentes

# 10. Vérifier que GitHub Pages se met à jour
# → https://yoyonel.github.io/rpi-internet-monitoring/
```

### Point critique : `loginctl enable-linger`

Par défaut, systemd user services sont **stoppés quand l'utilisateur se déconnecte** (fermeture SSH).
`enable-linger` fait persister les services même sans session active.

```bash
# Activer (une seule fois, persistant après reboot)
loginctl enable-linger latty

# Vérifier
loginctl show-user latty | grep Linger
# Linger=yes
```

**Sans cette commande, les timers s'arrêteront dès la déconnexion SSH.** C'est le piège classique
des systemd user timers sur un serveur headless.

### Rollback

Si quelque chose ne fonctionne pas, on peut revenir au crontab en 30 secondes :

```bash
# Désinstaller les timers
just uninstall-timers

# Remettre le crontab
crontab -e
# */10 * * * * cd /home/latty/rpi-internet-monitoring && /usr/bin/docker compose run --rm speedtest >/dev/null 2>&1
# */10 * * * * cd /home/latty/rpi-internet-monitoring && bash scripts/publish-gh-pages.sh 30 >/dev/null 2>&1
```

---

## Commandes de diagnostic

### État des timers

```bash
# Liste des timers actifs avec prochaine exécution
systemctl --user list-timers

# État détaillé d'un timer spécifique
systemctl --user status speedtest.timer
systemctl --user status publish-gh-pages.timer

# État du service (dernière exécution, exit code, durée)
systemctl --user status speedtest.service
systemctl --user status publish-gh-pages.service
```

### Logs

```bash
# Logs d'un service spécifique
journalctl --user -u speedtest.service --no-pager -n 20

# Logs avec timestamps et exit codes
journalctl --user -u speedtest.service -o verbose --no-pager -n 5

# Logs depuis le dernier boot
journalctl --user -u speedtest.service -b

# Logs en temps réel (follow)
journalctl --user -u speedtest.service -f

# Tous les logs des deux services
journalctl --user -u speedtest.service -u publish-gh-pages.service --no-pager -n 30

# Logs des erreurs uniquement
journalctl --user -u speedtest.service -p err --no-pager
```

### Exécution manuelle (debug)

```bash
# Lancer manuellement un service (sans attendre le timer)
systemctl --user start speedtest.service

# Vérifier le résultat
systemctl --user status speedtest.service
journalctl --user -u speedtest.service -n 1 --no-pager
```

---

## Troubleshooting

### Le timer ne fire pas

```bash
# Vérifier que le timer est enabled et active
systemctl --user is-enabled speedtest.timer    # → enabled
systemctl --user is-active speedtest.timer     # → active

# Si "inactive", redémarrer
systemctl --user start speedtest.timer

# Vérifier le lingering
loginctl show-user latty | grep Linger         # → Linger=yes
```

### Le service échoue

```bash
# Voir l'exit code et les logs
systemctl --user status speedtest.service
journalctl --user -u speedtest.service -n 10

# Causes fréquentes :
# - Docker daemon non démarré → sudo systemctl start docker
# - Image speedtest pas buildée → just build
# - Conteneur speedtest déjà en cours (ExecCondition skip) → docker ps | grep speedtest
# - Réseau Docker manquant → docker network ls
```

### Les timers s'arrêtent après déconnexion SSH

```bash
# Le lingering n'est pas activé
loginctl enable-linger latty

# Vérifier
loginctl show-user latty | grep Linger
```

### WorkingDirectory incorrect

```bash
# Vérifier le chemin dans le service installé
cat ~/.config/systemd/user/speedtest.service | grep WorkingDirectory

# Si incorrect, réinstaller :
just install-timers
# La recette re-copie et re-patche automatiquement
```

### Le publish échoue (git push)

```bash
journalctl --user -u publish-gh-pages.service -n 10

# Causes fréquentes :
# - Clé SSH non chargée → évaluer ssh-agent dans le service ou utiliser HTTPS + token
# - Pas de droits push sur le repo → gh auth status
# - Branche gh-pages inexistante → git ls-remote --heads origin gh-pages
```

**Note importante sur SSH** : dans un contexte systemd user sans session interactive, `ssh-agent`
n'est pas automatiquement démarré. Si le publish utilise SSH pour git push, il faudra soit :

- Configurer un `ssh-agent.service` systemd user
- Utiliser une clé SSH sans passphrase (moins sécurisé mais fonctionnel)
- Basculer le remote sur HTTPS avec un token GitHub (plus simple)

---

## Décisions & alternatives envisagées

### Alternative 1 : rester sur cron + wrapper script

**Idée** : garder cron mais écrire un script `scripts/cron-wrapper.sh` qui gère les logs, overlaps et timeouts.

**Rejeté car** :

- Réinventer la roue — systemd fait déjà tout ça nativement
- Le crontab lui-même reste hors repo (pas versionné)
- Pas de `Persistent` (catch-up après downtime)

### Alternative 2 : cron + `flock`

**Idée** : `*/10 * * * * flock -n /tmp/speedtest.lock docker compose run --rm speedtest`

**Rejeté car** :

- Résout seulement l'anti-overlap, pas les autres problèmes (logs, timeout, catch-up, versioning)
- `flock` ne gère pas le timeout natif

### Alternative 3 : Docker-native scheduling (ofelia, etc.)

**Idée** : utiliser un scheduler Docker comme [ofelia](https://github.com/mcuadros/ofelia) ou le
`deploy.restart_policy` de Docker Swarm pour planifier les tâches.

**Rejeté car** :

- Ajoute un service supplémentaire à maintenir
- Ofelia est un projet peu actif
- Swarm est overkill pour un RPi mono-node
- Le publish GH Pages a besoin de git (pas idéal dans un conteneur)

### Alternative 4 : GitHub Actions scheduled workflow

**Idée** : un workflow `schedule:` sur GitHub qui SSH vers le RPi pour lancer les tâches.

**Rejeté car** :

- Dépendance à GitHub (si GitHub Actions est down, plus de monitoring)
- Nécessite d'exposer le RPi en SSH sur internet (sécurité)
- Latence et overhead inutiles

### Choix final : systemd user timers

**Retenu car** :

- Zéro dépendance externe (systemd est déjà sur le RPi)
- Toutes les fonctionnalités nécessaires par défaut (logs, overlap, timeout, persistent, random delay)
- Fichiers versionnés dans le repo (infra as code)
- Installation/désinstallation en une commande
- Rollback trivial vers cron si besoin
- Standard Linux, documentation abondante

---

## Fichiers du projet

| Fichier                             | Rôle                                                            |
| ----------------------------------- | --------------------------------------------------------------- |
| `systemd/speedtest.service`         | Service oneshot : lance le conteneur speedtest                  |
| `systemd/speedtest.timer`           | Timer : toutes les 10 min, 30s random delay                     |
| `systemd/publish-gh-pages.service`  | Service oneshot : publie sur GitHub Pages                       |
| `systemd/publish-gh-pages.timer`    | Timer : toutes les 10 min, 60s random delay                     |
| `Justfile`                          | Recettes `install-timers` / `uninstall-timers` / `timer-status` |
| `docs/scheduling-systemd-timers.md` | Ce document                                                     |
