[MONITORER SON DÉBIT INTERNET](https://blog.eleven-labs.com/fr/monitorer-son-debit-internet/)

## Docker-compose & Dockerfile

```sh
╰─ docker-compose up -d

Pulling grafana (grafana/grafana:7.1.5)...
7.1.5: Pulling from grafana/grafana
df20fa9351a1: Pull complete
9942118288f3: Pull complete
1fb6e3df6e68: Pull complete
7e3d0d675cf3: Pull complete
4c1eb3303598: Pull complete
a5ec11eae53c: Pull complete
Digest: sha256:579044d31fad95f015c78dff8db25c85e2e0f5fdf37f414ce850eb045dd47265
Status: Downloaded newer image for grafana/grafana:7.1.5
Pulling influxdb (influxdb:1.8.2)...
1.8.2: Pulling from library/influxdb
4f250268ed6a: Pull complete
1b49aa113642: Pull complete
c159512f4cc2: Pull complete
517b77385dee: Pull complete
457fc04c0bf2: Pull complete
1bac4b017c6b: Pull complete
768bd597da06: Pull complete
a1b2fefecfca: Pull complete
Digest: sha256:10b5d97ee017eff85b07ab4c103fbe03f222a7e2432749f079c43d8f1ee48214
Status: Downloaded newer image for influxdb:1.8.2
Creating monitorersondbitinternet_grafana_1  ... done
Creating monitorersondbitinternet_influxdb_1 ... done

╰─ docker-compose ps
               Name                          Command           State                    Ports
---------------------------------------------------------------------------------------------------------------
monitorersondbitinternet_grafana_1    /run.sh                  Up      0.0.0.0:3000->3000/tcp,:::3000->3000/tcp
monitorersondbitinternet_influxdb_1   /entrypoint.sh influxd   Up      8086/tcp

# toute les 10 minutes, on lance le container exécutant speedtest
╰─ crontab -e
[...]
*/10 * * * * /storage/.kodi/addons/service.system.docker/bin/docker run --rm --network speedtest docker.local/speedtest:buster-slim > /storage/logs/speedtest.log 2>&1

# récupérer les logs du journal sur la tache cron (docker run) en filtrant sur les infos sur youtube
# ps: j'ai l'impression qu'il n'y a pas retention des lignes de logs, juste la dernière du dernier run du service cron ... :-|
╰─ journalctl --since "2 days ago" -u cron.service | grep youtube
Jun 15 15:50:32 LibreELEC crond[19218]: speedtest,result_id=2cb1090c-ca7c-4116-a7a2-91e9c567d12b ping_latency=6.736,download_bandwidth=117734699,upload_bandwidth=84024366,youtube_bandwidth=6.318474576271186
# [Crontab Log: How to Log the Output of My Cron Script](https://www.thegeekstuff.com/2012/07/crontab-log/)
```

## CONFIGURATION DE GRAFANA

url: http://localhost:3000/
user: admin
password: "***REDACTED***"

1. SOURCE DE DONNÉE INFLUXDB
2. CRÉATION DU DASHBOARD
   1. Import du JSON: [dashboard.json](https://gist.githubusercontent.com/VEBERArnaud/4d37935fe906324dd18ff01cb511eda6/raw/f3d650842c5edf8dc237c1f95713b8bf195cc751/dashboard.json)


## Résultats
Déployé sur le Dell-Debian, ça fonctionne bien.
(TODO: déployer et laisser tourner sur le raspberry)

## raspberry

### docker (engine)
[Turn a dedicated Kodi box into a Home Server using Docker](https://cwilko.github.io/home%20automation/2017/02/28/Raspberry-Pi-Home-Server.html)
`The solution presents itself with the addition of the Docker add-on to the OpenELEC/LibreELEC repository!`

### docker-compose
- [Docker compose on LE ?](https://forum.libreelec.tv/thread/13695-docker-compose-on-le/)
- [Installing Docker and Docker-Compose on ARM-based Systems](https://satishgadhave.medium.com/installing-docker-and-docker-compose-on-arm-based-systems-23b7a7a8d055)
- [linuxserver/docker-docker-compose](https://github.com/linuxserver/docker-docker-compose/releases/)

```sh
LibreELEC:~ # mkdir /storage/bin
LibreELEC:~ # nano /storage/.profile
    PATH=$HOME/bin:$PATH
LibreELEC:~ # curl -L "https://github.com/linuxserver/docker-docker-compose/releases/download/1.29.2-ls51/docker-compose-armhf" -o /storage/bin/docker-compose
LibreELEC:~ # chmod +x /storage/bin/docker-compose
LibreELEC:~ # cd /storage/bin
LibreELEC:~/bin # ./docker-compose --version
docker-compose version 1.29.2, build 5becea4c
```