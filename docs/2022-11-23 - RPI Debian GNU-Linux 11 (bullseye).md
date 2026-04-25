copie des sources vers le raspberry

```sh
╰─ scp -r MONITORER\ SON\ DÉBIT\ INTERNET/ user@<rpi-ip>:"/home/user/Prog"
telegraf.conf                                                                                                                 100%   12KB   3.6MB/s   00:00
Dockerfile                                                                                                                    100% 1314   510.5KB/s   00:00
README.md                                                                                                                     100%   14KB   5.2MB/s   00:00
speedtest - analyse CSV, JSON.md                                                                                              100% 4089     1.9MB/s   00:00
.python-version                                                                                                               100%    6     2.0KB/s   00:00
docker-compose.yml                                                                                                            100%  454   181.1KB/s   00:00
compute_average_download_biterate.py                                                                                          100% 1803   749.1KB/s   00:00
docker-entrypoint.sh                                                                                                          100% 1346   916.0KB/s   00:00
setup.sh                                                                                                                      100%  339   126.8KB/s   00:00
telegraf.conf                                                                                                                 100%   12KB   4.1MB/s   00:00
Dockerfile                                                                                                                    100% 1262   602.6KB/s   00:00
README.md                                                                                                                     100% 3961     1.7MB/s   00:00
docker-compose.yml                                                                                                            100% 1251   473.3KB/s   00:00
compute_average_download_biterate.py                                                                                          100% 1826   841.6KB/s   00:00
docker-entrypoint.sh                                                                                                          100% 1627   587.2KB/s   00:00
dashboard.json                                                                                                                100%   15KB   4.3MB/s   00:00
```

build de l'image (custom) docker pour speedtest (+ analyse des résultats) sur le raspberry:

```sh
user@raspberrypi:~/Prog/MONITORER SON DÉBIT INTERNET/RPI $ docker build -t docker.local/speedtest:buster-slim .
Sending build context to Docker daemon  29.18kB
Step 1/10 : FROM python:3.9.13-slim-buster
3.9.13-slim-buster: Pulling from library/python
a84b81edbdb8: Extracting [===============================>                   ]  16.25MB/25.91MB
...
Removing intermediate container f29f46abfc86
 ---> f1a3aa49df1f
Successfully built f1a3aa49df1f
Successfully tagged docker.local/speedtest:buster-slim
```

on lance le docker-compose:

```sh
user@raspberrypi:~/Prog/MONITORER SON DÉBIT INTERNET/RPI $ docker-compose up -d
Creating network "speedtest" with driver "bridge"
Creating volume "rpi_grafana-storage" with default driver
Creating volume "rpi_influxdb-data" with default driver
Creating volume "rpi_chronograf-data" with default driver
Pulling grafana (grafana/grafana:7.1.5)...
7.1.5: Pulling from grafana/grafana
b538f80385f9: Pull complete
0fd59ff5367f: Pull complete
4f4fb700ef54: Pull complete
a9898124c38f: Extracting [==============================================>    ]  41.75MB/45.07MB
...
Pulling influxdb (influxdb:1.8.2)...
1.8.2: Pulling from library/influxdb
3b396f138ad7: Pull complete
a5db606bd1cc: Pull complete
71dd3b5402f1: Pull complete
08b5628caff9: Pull complete
7ff8d1f3a81e: Pull complete
89e08e408a4b: Extracting [==================================================>]     228B/228B
...
Pulling chronograf (chronograf:)...
latest: Pulling from library/chronograf
f3ac85625e76: Extracting [==========================================>        ]  25.56MB/30.06MB
b1302dbefd89: Download complete
54ad8c453bfc: Download complete
25e940e47c5d: Download complete
...
Pulling telegraf (telegraf:)...
latest: Pulling from library/telegraf
077c13527d40: Extracting [=========>                                         ]  10.03MB/53.7MB
a3e29af4daf3: Download complete
3d7b1480fa4d: Download complete
8dacffc09706: Downloading [================================>                  ]  12.14MB/18.6MB
6a956f65aaa9: Download complete
afd1af3e3567: Downloading [============================================>      ]  35.66MB/40.28MB
...
Creating rpi_influxdb_1 ... done
Creating rpi_grafana_1  ... done
Creating telegraf       ... done
Creating chronograf     ... done
```

On check l'état des containers:

```sh
user@raspberrypi:~/Prog/MONITORER SON DÉBIT INTERNET/RPI $ docker ps
CONTAINER ID   IMAGE                   COMMAND                  CREATED          STATUS          PORTS                                       NAMES
b3043b4ecfc0   chronograf              "/entrypoint.sh chro…"   17 seconds ago   Up 15 seconds   0.0.0.0:8888->8888/tcp, :::8888->8888/tcp   chronograf
68017629e58d   telegraf                "/entrypoint.sh tele…"   17 seconds ago   Up 15 seconds   8092/udp, 8125/udp, 8094/tcp                telegraf
adade3449626   influxdb:1.8.2          "/entrypoint.sh infl…"   32 seconds ago   Up 17 seconds   8086/tcp                                    rpi_influxdb_1
c0ec069d023a   grafana/grafana:7.1.5   "/run.sh"                32 seconds ago   Up 17 seconds   0.0.0.0:3000->3000/tcp, :::3000->3000/tcp   rpi_grafana_1
user@raspberrypi:~/Prog/MONITORER SON DÉBIT INTERNET/RPI $ docker-compose ps
     Name                 Command            State                    Ports
---------------------------------------------------------------------------------------------
chronograf       /entrypoint.sh chronograf   Up      0.0.0.0:8888->8888/tcp,:::8888->8888/tcp
rpi_grafana_1    /run.sh                     Up      0.0.0.0:3000->3000/tcp,:::3000->3000/tcp
rpi_influxdb_1   /entrypoint.sh influxd      Up      8086/tcp
telegraf         /entrypoint.sh telegraf     Up      8092/udp, 8094/tcp, 8125/udp
```

(On peut lancer une exécution de l'image (custom) docker pour lancer notre workflow speedtest:

```sh
user@raspberrypi:~/Prog/MONITORER SON DÉBIT INTERNET/RPI $ docker run --rm docker.local/speedtest:buster-slim
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100    60    0    33  100    27   1375   1125 --:--:-- --:--:-- --:--:--  2500
{"results":[{"statement_id":0}]}
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100    60    0    33  100    27   8250   6{"results":[{"statement_id":0}]}   0
750 --:--:-- --:--:-- --:--:-- 15000
speedtest,result_id=a3fa59aa-3fae-466a-8546-30f60265dd8f ping_latency=11.709,download_bandwidth=116890097,upload_bandwidth=76832889,youtube_bandwidth=5.0776612903225775
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100   168    0     0  100   168      0    113  0:00:01  0:00:01 --:--:--   113
```

ℹ️Remarqueℹ️
Dans le `docker-entrypoint.sh` :

```shell
influxdb_db=${INFLUXDB_DB:-speedtest}
[...]
# Ensure InfluxDB database exists
curl \
    -d "q=CREATE DATABASE ${influxdb_db}" \
    "${influxdb_url}/query"
```

on s'assure que la DB existe dans InfluxDB avant de send des données dedans)

Connection à Grafana depuis l'extérieur:
url: http://<rpi-ip>:3000

1ère connection -> utiliser l'authent par défaut admin/admin,
puis définir un nouveau mot de passe (stocké dans .env: GF_SECURITY_ADMIN_PASSWORD)

Configuration Grafana:

- `/datasources/new?utm_source=grafana_gettingstarted`
  Add data source > Data Sources / InfluxDB
  Name: InfluxDB
  HTTP / URL : http://influxdb:8086
  (container docker du service InfluxDB)
- InfluxDB Details / Database : speedtest

`/dashboard/import`
Import
Import dashboard from file or Grafana.com
Import via panel json
on copie colle depuis: `https://gist.githubusercontent.com/VEBERArnaud/4d37935fe906324dd18ff01cb511eda6/raw/f3d650842c5edf8dc237c1f95713b8bf195cc751/dashboard.json`
et on `Load`
Name: "InfluxDB"

> `Import`
> Et voilà ! :-D

configuration de la tâche CRON:

```sh
user@raspberrypi:~/Prog/MONITORER SON DÉBIT INTERNET/RPI $ which docker
/usr/bin/docker
user@raspberrypi:~/Prog/MONITORER SON DÉBIT INTERNET/RPI $ crontab -e
...
user@raspberrypi:~/Prog/MONITORER SON DÉBIT INTERNET/RPI $ crontab -l
# Edit this file to introduce tasks to be run by cron.
[...]
# m h  dom mon dow   command
*/10 * * * * /usr/bin/docker run --rm --network speedtest docker.local/speedtest:buster-slim
```

Configuration de Telegraph/Grafana:
Configuration Grafana:

- `/datasources/new?utm_source=grafana_gettingstarted`
  Name: Telegraph
  Add data source > Data Sources / InfluxDB
  HTTP / URL : http://influxdb:8086
  (container docker du service InfluxDB)
- InfluxDB Details / Database : telegraf

`/dashboard/import`
Import
Import dashboard from file or Grafana.com
Import via panel json
on copie colle depuis: `https://gist.githubusercontent.com/VEBERArnaud/4d37935fe906324dd18ff01cb511eda6/raw/f3d650842c5edf8dc237c1f95713b8bf195cc751/dashboard.json`
et on `Load`
Name: "Single System Dashboard (Using Telegraf and InfluxDB)"

> `Import`
> Et voilà ! :-D

=> fonctionnel !
