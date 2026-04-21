# Étude comparative : Ookla Speedtest CLI vs iperf3

**Date** : 2026-04-21
**Contexte** : Évaluation de iperf3 (avec serveurs publics gratuits via [iperf.fr](https://iperf.fr/iperf-servers.php)) comme alternative ou complément à Ookla Speedtest CLI utilisé dans le projet.
**Décision** : Conserver Speedtest CLI comme outil principal.

---

## 1. Setup actuel du projet

Le projet utilise **Ookla Speedtest CLI** (binaire officiel, pas le vieux `speedtest-cli` Python) :

- Container Docker dédié (`Dockerfile`) basé sur `debian:bookworm-slim`
- Exécuté **toutes les 10 min** via systemd timer (`systemd/speedtest.timer`)
- Le script `docker-entrypoint.sh` lance `speedtest -f json`, extrait `ping_latency`, `download_bandwidth`, `upload_bandwidth` via `jq`, et écrit dans InfluxDB
- Dashboard Grafana dédié (`speedtest/dashboard.json`)

---

## 2. Comparaison fonctionnelle

| Critère                   | **Ookla Speedtest CLI** (actuel)                             | **iperf3 + serveurs publics**                                                            |
| ------------------------- | ------------------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| **Ce qui est mesuré**     | Download, Upload, Ping latency, Jitter, Packet loss          | Throughput TCP/UDP brut (unidirectionnel ou bidirectionnel), Jitter, Packet loss (UDP)   |
| **Protocoles**            | HTTP/HTTPS (simule usage web réel)                           | TCP, UDP, SCTP pur                                                                       |
| **Sélection serveur**     | Automatique (serveur Ookla le plus proche) ou `--server-id`  | Manuel : choix explicite du serveur + port                                               |
| **Infra serveur**         | ~16 000 serveurs Ookla mondiaux, haute dispo                 | ~30-50 serveurs publics communautaires (cf. iperf.fr)                                    |
| **Disponibilité serveur** | Multi-connexions simultanées OK                              | **1 seule connexion à la fois** par processus serveur. Erreur `server is busy` fréquente |
| **Output JSON**           | Oui, natif (`-f json`) — riche (ISP, serveur, URL résultat…) | Oui (`--json`) — brut (bandwidth, intervals, streams)                                    |
| **Direction du test**     | Download + Upload en un seul run                             | Un sens à la fois par défaut. `-R` pour reverse (download). `--bidir` pour les deux      |
| **Durée test**            | ~20-40s (auto-adaptatif)                                     | Configurable (`-t`, défaut 10s)                                                          |
| **Installation**          | Dépôt Ookla officiel (apt)                                   | `apt install iperf3` (dans les repos Debian standard)                                    |
| **Licence**               | Propriétaire (--accept-license --accept-gdpr)                | BSD open-source                                                                          |
| **Dépendances**           | curl, jq, gnupg pour le repo                                 | Aucune (binaire standalone)                                                              |
| **Image Docker**          | Image custom ~120 Mo                                         | Pourrait être ~30 Mo (iperf3 seul)                                                       |

---

## 3. Comparaison technique pour le monitoring

| Aspect                           | **Speedtest CLI**                                                                            | **iperf3**                                                                                               |
| -------------------------------- | -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| **Représentativité "vraie vie"** | **Excellente** — simule un usage web réel (HTTP multi-thread, sélection serveur intelligent) | **Moyenne** — mesure la capacité réseau brute, pas l'expérience utilisateur                              |
| **Reproductibilité**             | Bonne (même serveur auto-sélectionné)                                                        | **Supérieure** — contrôle total du serveur, port, protocole, nombre de streams, taille fenêtre           |
| **Fiabilité en cron**            | **Très fiable** — les serveurs Ookla sont toujours disponibles                               | **Risqué** — les serveurs publics sont souvent `busy`, `OOS` (Out of Service), ou supprimés sans préavis |
| **Neutralité réseau**            | Les ISP peuvent prioriser le trafic vers les serveurs Ookla (connu et documenté)             | **Meilleur** pour détecter le throttling ISP — trafic non identifiable comme "speedtest"                 |
| **Granularité**                  | Résultat global agrégé                                                                       | Résultats par intervalle (chaque seconde), par stream, configurable                                      |
| **Tests UDP**                    | Non                                                                                          | Oui (`-u` avec `-b` pour le bitrate cible)                                                               |
| **Contrôle congestion**          | Non configurable                                                                             | Configurable (`--congestion BBR`, `Cubic`…)                                                              |
| **Consommation bande passante**  | ~200-500 Mo par test (download+upload)                                                       | Configurable : de quelques Ko à saturation                                                               |

---

## 4. Problèmes concrets de iperf3 pour ce projet

### a) Fiabilité des serveurs publics — point critique

- Serveurs communautaires = pas de SLA, pannes fréquentes
- `iperf3: error - the server is busy running a test. try again later` très courant
- Sur la page iperf.fr, plusieurs serveurs sont déjà marqués `OOS 03/2025`
- Il faudrait implémenter un **fallback multi-serveurs** avec retry, ce qui complexifie le script

### b) Pas de mesure download+upload en un seul run

- Il faudrait 2 commandes : `iperf3 -c server -t 10` (upload) + `iperf3 -c server -t 10 -R` (download)
- Ou `--bidir` mais ce n'est pas supporté par tous les serveurs

### c) Pas de ping/latency natif

- iperf3 ne mesure pas la latency au sens speedtest. Il faudrait compléter avec `ping` séparé
- Le setup actuel collecte déjà la latency via Telegraf (`inputs.net`), mais la latency Speedtest est liée au serveur de test

### d) Intégration InfluxDB

- Le JSON iperf3 a une structure très différente — il faudrait réécrire `docker-entrypoint.sh` et adapter le dashboard Grafana

---

## 5. Où iperf3 serait pertinent (si besoin futur)

| Cas d'usage                         | Intérêt                                                                               |
| ----------------------------------- | ------------------------------------------------------------------------------------- |
| **Détecter du traffic shaping ISP** | iperf3 vers un serveur non-Ookla peut révéler un throttling que Speedtest ne voit pas |
| **Diagnostiquer le réseau local**   | iperf3 entre 2 machines LAN = test du switch/Wi-Fi, sans dépendance Internet          |
| **Tests UDP / VoIP / streaming**    | Seul iperf3 peut tester UDP avec jitter et packet loss                                |
| **Benchmark réseau avancé**         | Contrôle du nombre de streams parallèles, taille de buffer, congestion control        |

---

## 6. Serveurs publics iperf3 notables (Europe/France)

| Serveur                    | Localisation                     | Vitesse    | Ports     | Statut (03/2025) |
| -------------------------- | -------------------------------- | ---------- | --------- | ---------------- |
| `ping.online.net`          | France, Île-de-France (Scaleway) | 100 Gbit/s | 5200-5209 | OK               |
| `iperf3.moji.fr`           | France, Île-de-France (Moji)     | 100 Gbit/s | 5200-5240 | OK               |
| `speedtest.milkywan.fr`    | France, Île-de-France (MilkyWan) | 40 Gbit/s  | 9200-9240 | OK               |
| `paris.bbr.iperf.bytel.fr` | France, Paris (Bouygues)         | —          | —         | OK               |
| `speedtest.serverius.net`  | Netherlands (Serverius)          | 10 Gbit/s  | 5002      | OK               |

Source : <https://iperf.fr/iperf-servers.php>

---

## 7. Conclusion

**Speedtest CLI reste le meilleur choix** pour le monitoring continu sur RPi :

- **Fiabilité** : infrastructure Ookla robuste vs serveurs communautaires fragiles
- **Simplicité** : un seul run = download + upload + ping, JSON riche
- **Pertinence** : mesure l'expérience utilisateur réelle, pas le throughput brut
- **Intégration** : déjà en place, testé, avec dashboard Grafana

iperf3 est un outil complémentaire puissant pour du diagnostic ponctuel ou de la détection de throttling ISP, mais inadapté comme remplacement pour du monitoring automatisé fiable.
