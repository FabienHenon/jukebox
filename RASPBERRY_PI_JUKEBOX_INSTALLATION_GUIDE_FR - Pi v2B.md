# Installation complète du jukebox sur Raspberry Pi 2 B

Guide mis à jour le 16 septembre 2026.

Ce guide part de zéro. Il suppose que tu disposes maintenant de :

- un Raspberry Pi 2 Model B avec 1 Go de RAM ;
- une carte microSD de 16 Go qui peut contenir une ancienne installation ;
- un écran HDMI non tactile ;
- une application Phoenix/LiveView terminée sur ton ordinateur ;
- un iPhone qui enverra la musique par AirPlay ;
- un amplificateur TPA3116D2 et des haut-parleurs passifs ;
- plus tard, des boutons physiques et des éclairages LED basse tension.

La cible est volontairement légère :

- Raspberry Pi OS Lite 32 bits ;
- aucune interface de bureau complète ;
- Shairport Sync relié directement à ALSA ;
- Mosquitto pour les métadonnées et les commandes ;
- Phoenix sous forme de release de production ARMv7 ;
- PostgreSQL uniquement si l'application l'utilise réellement ;
- X11, Openbox et un seul Chromium en mode kiosk ;
- services `systemd` pour tout relancer automatiquement.

```mermaid
flowchart TD
    I["iPhone / YouTube Music"] -->|"AirPlay classique"| S["Shairport Sync"]
    S -->|"Audio"| A["ALSA → DAC → amplificateur"]
    S -->|"Métadonnées MQTT"| M["Mosquitto"]
    M --> P["Phoenix / LiveView"]
    P --> C["Chromium kiosk → écran"]
    B["Boutons GPIO"] --> P
```

Le Pi 2 est assez puissant pour l'audio et Phoenix. Chromium sera le composant limitant. Nous éviterons donc Docker, le bureau complet, les effets graphiques lourds et les services inutiles.

> Important : ne commence pas encore les branchements GPIO. On valide d'abord le système, le réseau, le son, AirPlay et l'application.

---

# Phase 0 — Préparer le matériel

## Matériel nécessaire pour l'installation

- Raspberry Pi 2 Model B ;
- alimentation micro-USB stable de 5 V / 2 à 2,5 A ;
- carte microSD de 16 Go ;
- lecteur de microSD pour le Mac ;
- écran et câble HDMI ;
- câble Ethernet relié à la box ;
- clavier USB uniquement pour le dépannage ;
- câble jack 3,5 mm ou DAC USB pour le son ;
- un autre ordinateur connecté au même réseau.

Le Pi 2 ne possède pas de Wi-Fi intégré. Le câble Ethernet est donc la solution recommandée. Une clé Wi-Fi USB compatible Linux pourra être ajoutée plus tard si le câble est impossible.

## Sauvegarder l'ancienne carte si nécessaire

Raspberry Pi Imager va effacer entièrement la carte. Si elle contient quelque chose d'important, crée d'abord une image de sauvegarde ou utilise une autre carte.

Une carte de 16 Go suffit pour ce montage minimal, mais une carte ancienne peut être lente ou usée. Pour la version définitive, une microSD neuve de 32 Go, A1/A2 ou High Endurance, restera préférable.

---

# Phase 1 — Installer Raspberry Pi OS Lite 32 bits

## 1. Installer Raspberry Pi Imager sur le Mac

Télécharge Raspberry Pi Imager depuis :

https://www.raspberrypi.com/software/

Installe puis ouvre l'application.

## 2. Écrire le bon système sur la microSD

Dans Raspberry Pi Imager :

1. `Choose Device` : sélectionne `Raspberry Pi 2` ou `Raspberry Pi 2 Model B`.
2. `Choose OS` : ouvre `Raspberry Pi OS (other)`.
3. Sélectionne **Raspberry Pi OS Lite (32-bit)**.
4. Vérifie qu'il s'agit bien de la version 32 bits sans environnement graphique.
5. Ne sélectionne ni 64 bits, ni Desktop, ni Full.
6. `Choose Storage` : sélectionne uniquement la carte de 16 Go.

À la date de ce guide, la version courante est basée sur Debian 13 `trixie`, compatible avec tous les Raspberry Pi et occupant environ 2,6 Go après installation. Elle fournit aussi une version récente d'Elixir, ce qui simplifie le déploiement de l'application Phoenix.

Dans les réglages avancés d'Imager, utilise :

| Réglage | Valeur |
| --- | --- |
| Hostname | `jukebox` |
| Username | `jukebox` |
| Password | un mot de passe provisoire solide |
| Timezone | `Europe/Paris` |
| Keyboard | `fr` |
| SSH | activé, mot de passe autorisé pour le premier démarrage |

Tu peux laisser les champs Wi-Fi vides si tu utilises Ethernet. Si tu possèdes déjà une clé Wi-Fi USB compatible, tu peux saisir le SSID, le mot de passe et le pays `FR`, mais garde l'Ethernet branché pour la première installation.

Lance `Write`, confirme l'effacement puis attends la fin de la vérification.

## 3. Premier démarrage

Raspberry totalement débranché :

1. insère la carte microSD ;
2. branche l'écran HDMI ;
3. branche le câble Ethernet ;
4. branche temporairement un clavier si tu le souhaites ;
5. ne branche encore aucun bouton ou MOSFET sur les GPIO ;
6. branche l'alimentation micro-USB en dernier.

Attends trois à cinq minutes pour le premier démarrage.

## 4. Se connecter en SSH depuis le Mac

Dans Terminal :

```bash
ssh jukebox@jukebox.local
```

Réponds `yes`, puis saisis le mot de passe créé dans Imager.

Si le nom local ne répond pas, récupère l'adresse IP dans l'interface de ta box, puis utilise par exemple :

```bash
ssh jukebox@192.168.1.42
```

## 5. Vérifier que la bonne architecture est installée

```bash
cat /proc/device-tree/model
echo
uname -m
dpkg --print-architecture
cat /etc/os-release
free -h
df -h /
```

Résultats attendus :

- le modèle contient `Raspberry Pi 2 Model B` ;
- `uname -m` affiche normalement `armv7l` ;
- l'architecture Debian est `armhf` ;
- le système est 32 bits ;
- la mémoire totale est proche de 1 Go ;
- plusieurs gigaoctets restent libres.

Même si certaines révisions du Pi 2 possèdent un processeur capable de 64 bits, nous conservons volontairement l'OS 32 bits pour assurer la compatibilité avec toutes les révisions.

## 6. Mettre le système à jour

```bash
sudo apt update
sudo apt -y full-upgrade
sudo apt clean
sudo reboot
```

Attends deux à trois minutes, puis reconnecte-toi en SSH.

## 7. Installer les outils de base

```bash
sudo apt install -y --no-install-recommends \
  git curl ca-certificates rsync nano htop file openssl \
  build-essential pkg-config \
  alsa-utils avahi-daemon avahi-utils \
  mosquitto mosquitto-clients
```

Active Avahi, qui permet à l'iPhone de découvrir le jukebox sur le réseau :

```bash
sudo systemctl enable --now avahi-daemon
systemctl is-active avahi-daemon
```

La dernière commande doit répondre `active`.

## 8. Limiter les journaux sur la carte de 16 Go

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
sudo nano /etc/systemd/journald.conf.d/jukebox.conf
```

Ajoute :

```ini
[Journal]
SystemMaxUse=100M
RuntimeMaxUse=50M
MaxRetentionSec=7day
```

Puis applique :

```bash
sudo systemctl restart systemd-journald
sudo journalctl --vacuum-size=100M
df -h /
```

---

# Phase 2 — Installer un environnement graphique minimal

Nous n'installons pas le bureau Raspberry Pi. Nous ajoutons uniquement ce dont Chromium a besoin.

```bash
sudo apt install -y --no-install-recommends \
  xserver-xorg x11-xserver-utils xinit openbox \
  chromium unclutter
```

Ajoute l'utilisateur aux groupes utiles :

```bash
sudo usermod -aG audio,video,input,render,gpio jukebox
```

Configure une connexion automatique sur la console :

```bash
sudo raspi-config
```

Dans les menus :

1. `System Options` ;
2. `Boot / Auto Login` ;
3. choisis **Console Autologin** ;
4. ne choisis pas Desktop Autologin ;
5. quitte avec `Finish` sans ajouter encore le lancement de Chromium.

Nous terminerons la configuration kiosk après avoir installé Phoenix.

---

# Phase 3 — Valider le son avant AirPlay

Ne continue pas tant que Linux ne produit pas un son correct.

## 1. Brancher provisoirement l'audio

Deux possibilités :

- sortie jack 3,5 mm du Pi vers l'entrée jack de l'amplificateur ;
- DAC USB branché au Pi, puis sortie du DAC vers l'amplificateur.

Commence avec le volume de l'amplificateur très bas.

## 2. Lister les périphériques ALSA

```bash
aplay -l
aplay -L
```

Conserve cette sortie. Le nom exact du DAC servira éventuellement dans la configuration Shairport.

## 3. Faire un test stéréo

```bash
speaker-test -c 2 -t wav -D default
```

Tu dois entendre alternativement `Front Left` et `Front Right`. Arrête avec `Ctrl+C`.

Si aucun son ne sort :

```bash
alsamixer
```

- `F6` : sélectionner la carte audio ;
- flèches : régler le volume ;
- `M` : retirer le mute ;
- `Esc` : quitter.

La sortie jack suffit pour le premier test. Le DAC USB est recommandé pour réduire le souffle dans la version finale.

---

# Phase 4 — Configurer MQTT localement

Mosquitto doit être accessible uniquement depuis le Raspberry.

```bash
sudo nano /etc/mosquitto/conf.d/jukebox-local.conf
```

Ajoute :

```conf
listener 1883 127.0.0.1
allow_anonymous true
persistence false
```

Puis :

```bash
sudo systemctl enable --now mosquitto
sudo systemctl restart mosquitto
systemctl is-active mosquitto
```

Test rapide dans une première session SSH :

```bash
mosquitto_sub -h 127.0.0.1 -t jukebox/test
```

Dans une seconde session :

```bash
mosquitto_pub -h 127.0.0.1 -t jukebox/test -m bonjour
```

La première session doit afficher `bonjour`. Arrête-la avec `Ctrl+C`.

---

# Phase 5 — Installer Shairport Sync

Nous utilisons **AirPlay classique** dans la première version : il est suffisant pour un seul jukebox et permet le contrôle distant le plus mature dans Shairport Sync.

Sur Raspberry Pi OS Lite, il n'y a ni PipeWire ni PulseAudio. Shairport utilisera donc ALSA directement et fonctionnera comme service système.

## 1. Installer les dépendances

```bash
sudo apt install -y --no-install-recommends \
  autoconf automake libtool \
  libpopt-dev libconfig-dev libasound2-dev \
  libavahi-client-dev libssl-dev libsoxr-dev \
  libavutil-dev libavcodec-dev libavformat-dev \
  libmosquitto-dev
```

Sous Debian 13 `trixie`, Shairport demande également `systemd-dev`. Vérifie d'abord ce que ferait APT :

```bash
sudo apt install --dry-run --no-install-recommends systemd-dev
```

Si aucune suppression ou rétrogradation importante n'est proposée :

```bash
sudo apt install -y --no-install-recommends systemd-dev
```

En cas de proposition inhabituelle, ne confirme pas et conserve la sortie.

## 2. Télécharger et compiler

```bash
mkdir -p /home/jukebox/src
cd /home/jukebox/src
git clone --depth 1 https://github.com/mikebrady/shairport-sync.git
cd shairport-sync
autoreconf -fi
./configure \
  --sysconfdir=/etc \
  --with-alsa \
  --with-soxr \
  --with-avahi \
  --with-ssl=openssl \
  --with-systemd-startup \
  --with-ffmpeg \
  --with-mqtt-client
make -j1
sudo make install
```

`make -j1` est volontaire : il réduit le risque de manquer de mémoire sur le Pi 2.

## 3. Vérifier les fonctions compilées

```bash
shairport-sync -V
```

La chaîne doit mentionner au minimum ALSA, Avahi, metadata et MQTT. Si `mqtt` est absent, ne continue pas.

## 4. Configurer Shairport

```bash
sudo cp /etc/shairport-sync.conf /etc/shairport-sync.conf.original
sudo nano /etc/shairport-sync.conf
```

Remplace le contenu par :

```conf
general =
{
  name = "Jukebox";
  output_backend = "alsa";
  interpolation = "auto";
};

alsa =
{
  output_device = "default";
};

metadata =
{
  enabled = "yes";
  include_cover_art = "yes";
  cover_art_cache_directory = "/tmp/shairport-sync/.cache/coverart";
  progress_interval = 1.0;
};

sessioncontrol =
{
  active_state_timeout = 10.0;
};

mqtt =
{
  enabled = "yes";
  hostname = "127.0.0.1";
  port = 1883;
  topic = "jukebox/shairport";
  publish_raw = "yes";
  publish_parsed = "yes";
  publish_cover = "yes";
  publish_retain = "no";
  enable_remote = "yes";
};
```

Si `speaker-test -D default` ne fonctionnait pas mais qu'un nom précis de `aplay -L` fonctionnait, remplace uniquement `output_device = "default"` par ce nom.

## 5. Activer le service système

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now shairport-sync
sudo systemctl status shairport-sync --no-pager
```

Il doit être `active (running)`.

Si le service ne peut pas ouvrir ALSA :

```bash
systemctl show shairport-sync -p User
journalctl -u shairport-sync -n 100 --no-pager
```

Ne crée pas parallèlement un service utilisateur : une seule instance Shairport doit fonctionner.

## 6. Tester AirPlay

1. vérifie que l'iPhone est connecté au même réseau que le Pi ;
2. lance une chanson dans YouTube Music ;
3. ouvre le sélecteur AirPlay ;
4. sélectionne `Jukebox` ;
5. vérifie le son et le volume.

Pour suivre les logs :

```bash
journalctl -u shairport-sync -f
```

## 7. Tester les métadonnées MQTT

```bash
mosquitto_sub -h 127.0.0.1 -v -t 'jukebox/shairport/#'
```

Change de morceau. Tu devrais voir notamment `title`, `artist`, `album`, `play_start`, `active_start` et éventuellement la pochette binaire.

## 8. Tester les commandes vers l'iPhone

Pendant la lecture :

```bash
mosquitto_pub -h 127.0.0.1 \
  -t 'jukebox/shairport/remote' \
  -m 'playpause'
```

Puis :

```bash
mosquitto_pub -h 127.0.0.1 -t 'jukebox/shairport/remote' -m 'nextitem'
mosquitto_pub -h 127.0.0.1 -t 'jukebox/shairport/remote' -m 'previtem'
```

Ces commandes dépendent aussi du client AirPlay et de YouTube Music. Si elles ne fonctionnent pas mais que l'audio fonctionne, le problème ne vient pas du Pi 2.

---

# Phase 6 — Copier et examiner l'application Phoenix

Cette phase est le seul point où les vrais fichiers générés par Fable sont indispensables. Il ne faut pas deviner le nom de la release, les variables d'environnement ou l'utilisation de PostgreSQL.

## 1. Copier le projet depuis le Mac

Depuis le Mac, adapte le chemin :

```bash
rsync -av \
  --exclude '_build' \
  --exclude 'deps' \
  --exclude 'assets/node_modules' \
  /chemin/vers/application-jukebox/ \
  jukebox@jukebox.local:/home/jukebox/src/jukebox-app/
```

Si le projet est dans Git :

```bash
cd /home/jukebox/src
git clone URL_DU_DEPOT jukebox-app
```

N'ajoute jamais de token directement dans l'URL.

## 2. Relever les informations réelles

Sur le Pi :

```bash
cd /home/jukebox/src/jukebox-app
grep -n 'app:' mix.exs | head
grep -n 'elixir:' mix.exs | head
grep -nE 'postgrex|ecto_sql' mix.exs
find . -maxdepth 2 -type f \( \
  -name '.tool-versions' -o \
  -name 'mise.toml' -o \
  -name 'Dockerfile' -o \
  -name 'package.json' \
\) -print
grep -R 'System.get_env' config lib | sort
find ops docs rel -maxdepth 3 -type f -print 2>/dev/null | sort
```

### Point de contrôle obligatoire

Conserve ou transmets les sorties avant de continuer. Elles permettent de connaître :

- le vrai nom OTP de l'application ;
- la version minimale d'Elixir et d'Erlang ;
- l'utilisation éventuelle de PostgreSQL ;
- les variables d'environnement reconnues ;
- la commande de migration ;
- les éventuels services déjà fournis ;
- les numéros GPIO attendus par l'application.

Les exemples suivants utilisent `jukebox` comme nom de release. Remplace-le partout si `mix.exs` indique un autre nom.

---

# Phase 7 — Installer Elixir et compiler une release ARMv7

Une release compilée sur macOS, x86_64 ou ARM64 ne peut pas fonctionner sur ce Pi. Elle doit contenir une VM Erlang Linux `armhf/armv7` compatible.

## 1. Installer Elixir et Erlang

```bash
sudo apt install -y elixir erlang-dev
elixir --version
```

Sur Debian 13, la version fournie est normalement Elixir 1.18.x avec Erlang/OTP 27.x. Compare-la à `mix.exs`, `.tool-versions` ou `mise.toml`.

Si la contrainte n'est pas respectée, arrête-toi : ne modifie pas artificiellement `mix.exs`. Il faudra produire la release ARMv7 avec la bonne paire Erlang/Elixir.

## 2. Installer Hex et Rebar

```bash
mix local.hex --force
mix local.rebar --force
```

## 3. Installer Node uniquement si le projet en a besoin

Si `assets/package.json` existe et que les alias Mix lancent `npm` :

```bash
sudo apt install -y nodejs npm
```

Si l'application utilise uniquement les wrappers `esbuild` et `tailwind` d'Elixir, cette installation peut être inutile.

## 4. Compiler et lancer les tests

```bash
cd /home/jukebox/src/jukebox-app
mix deps.get
mix compile --warnings-as-errors
mix test
```

Le Pi 2 peut mettre longtemps. Ne ferme pas la session pendant la compilation.

Si le processus est tué faute de mémoire, crée temporairement 1 Go de swap :

```bash
sudo fallocate -l 1G /swapfile-build
sudo chmod 600 /swapfile-build
sudo mkswap /swapfile-build
sudo swapon /swapfile-build
free -h
```

Après la compilation complète, retire ce swap temporaire :

```bash
sudo swapoff /swapfile-build
sudo rm /swapfile-build
```

## 5. Construire la release

```bash
cd /home/jukebox/src/jukebox-app
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release --overwrite
```

Trouve son nom :

```bash
find _build/prod/rel -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
```

Puis vérifie qu'elle est bien construite sur le Pi :

```bash
file _build/prod/rel/jukebox/erts-*/bin/beam.smp
```

La sortie doit correspondre à un exécutable ELF 32 bits ARM.

## 6. Installer la release

```bash
sudo mkdir -p /opt/jukebox
sudo rsync -a --delete \
  /home/jukebox/src/jukebox-app/_build/prod/rel/jukebox/ \
  /opt/jukebox/
sudo chown -R jukebox:jukebox /opt/jukebox
```

Adapte `jukebox` si le vrai nom est différent.

---

# Phase 8 — Configurer PostgreSQL si l'application l'utilise

Ignore entièrement cette phase si `mix.exs` n'utilise ni `postgrex` ni `ecto_sql`, et si `runtime.exs` ne demande pas `DATABASE_URL`.

## 1. Installer PostgreSQL

```bash
sudo apt install -y postgresql
sudo systemctl enable --now postgresql
```

## 2. Créer un utilisateur et une base

Génère d'abord un mot de passe alphanumérique :

```bash
openssl rand -hex 24
```

Copie-le, puis ouvre PostgreSQL :

```bash
sudo -u postgres psql
```

Dans PostgreSQL, remplace `MOT_DE_PASSE` :

```sql
CREATE ROLE jukebox_app LOGIN PASSWORD 'MOT_DE_PASSE';
CREATE DATABASE jukebox_prod OWNER jukebox_app;
\q
```

Pour limiter les connexions de l'application, nous utiliserons ensuite `POOL_SIZE=5`.

---

# Phase 9 — Configurer Phoenix comme service

## 1. Générer le secret Phoenix

```bash
cd /home/jukebox/src/jukebox-app
mix phx.gen.secret
```

Conserve cette valeur sans la publier.

## 2. Créer le fichier d'environnement

```bash
sudo nano /etc/jukebox.env
```

Base indicative :

```text
PHX_SERVER=true
PHX_HOST=localhost
PORT=4000
SECRET_KEY_BASE=COLLER_ICI_LE_SECRET

JUKEBOX_METADATA_ADAPTER=mqtt
JUKEBOX_MQTT_HOST=127.0.0.1
JUKEBOX_MQTT_PORT=1883
JUKEBOX_MQTT_TOPIC=jukebox/shairport
JUKEBOX_REMOTE_CONTROL_ENABLED=true
JUKEBOX_IDLE_TIMEOUT_MS=10000
```

Si PostgreSQL est utilisé, ajoute avec le véritable mot de passe :

```text
DATABASE_URL=ecto://jukebox_app:MOT_DE_PASSE@127.0.0.1/jukebox_prod
POOL_SIZE=5
```

Les noms exacts doivent correspondre à `config/runtime.exs`. Supprime toute variable inventée qui n'est pas lue par l'application.

Protège le fichier :

```bash
sudo chown root:root /etc/jukebox.env
sudo chmod 600 /etc/jukebox.env
```

## 3. Créer le service

```bash
sudo nano /etc/systemd/system/jukebox.service
```

```ini
[Unit]
Description=Phoenix Jukebox
After=network-online.target mosquitto.service
Wants=network-online.target
Requires=mosquitto.service

[Service]
Type=simple
User=jukebox
Group=jukebox
WorkingDirectory=/opt/jukebox
EnvironmentFile=/etc/jukebox.env
ExecStart=/opt/jukebox/bin/server
Restart=on-failure
RestartSec=3
TimeoutStopSec=30
KillSignal=SIGTERM
SyslogIdentifier=jukebox

[Install]
WantedBy=multi-user.target
```

Si la release ne contient pas `/opt/jukebox/bin/server`, utilise :

```ini
ExecStart=/opt/jukebox/bin/jukebox start
```

en remplaçant `jukebox` par le vrai nom.

Si PostgreSQL est utilisé, ajoute `postgresql.service` aux lignes `After=` et `Requires=`.

## 4. Exécuter les migrations si nécessaire

La commande dépend du module réellement fourni par l'application. Une release Phoenix générée avec les outils standards utilise souvent une commande du type :

```bash
sudo systemd-run --pipe --wait --collect \
  --unit=jukebox-migrate \
  --property=User=jukebox \
  --property=WorkingDirectory=/opt/jukebox \
  --property=EnvironmentFile=/etc/jukebox.env \
  /opt/jukebox/bin/jukebox eval 'Jukebox.Release.migrate()'
```

Ne lance pas cet exemple avant d'avoir vérifié le vrai nom du module dans `lib/` ou `rel/overlays/bin/migrate`.

## 5. Démarrer Phoenix

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now jukebox
sudo systemctl status jukebox --no-pager
curl --fail http://127.0.0.1:4000/ >/dev/null && echo 'Phoenix OK'
```

En cas d'erreur :

```bash
journalctl -u jukebox -n 150 --no-pager
```

---

# Phase 10 — Lancer Chromium automatiquement en mode kiosk

## 1. Créer le script X11

```bash
nano /home/jukebox/.xinitrc
```

Ajoute :

```bash
#!/bin/sh

xset -dpms
xset s off
xset s noblank
xsetroot -solid black

unclutter -idle 0.2 -root &
openbox-session &

until curl --max-time 2 --fail --silent http://127.0.0.1:4000/ >/dev/null; do
  sleep 1
done

exec chromium \
  --ozone-platform=x11 \
  --kiosk \
  --noerrdialogs \
  --no-first-run \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --disable-background-networking \
  --disable-component-update \
  --disable-features=Translate \
  --renderer-process-limit=2 \
  --disk-cache-size=52428800 \
  --media-cache-size=52428800 \
  --autoplay-policy=no-user-gesture-required \
  http://127.0.0.1:4000/
```

Puis :

```bash
chmod +x /home/jukebox/.xinitrc
```

Ne rajoute pas `--disable-gpu` : le Pi 2 a besoin de son accélération graphique pour afficher correctement l'interface.

## 2. Lancer X automatiquement uniquement sur la console locale

```bash
nano /home/jukebox/.bash_profile
```

Ajoute :

```bash
if [ -z "$DISPLAY" ] && [ "${XDG_VTNR:-0}" = "1" ]; then
  exec startx
fi
```

Cette condition ne lance pas Chromium dans les connexions SSH.

## 3. Tester le démarrage complet

```bash
sudo reboot
```

Résultat attendu :

1. Linux démarre ;
2. la console ouvre automatiquement la session `jukebox` ;
3. Shairport, Mosquitto et Phoenix démarrent ;
4. X11 et Openbox se lancent ;
5. Chromium attend que Phoenix réponde ;
6. l'interface apparaît en plein écran.

Le Pi 2 peut mettre une à deux minutes avant d'afficher l'application.

## 4. Vérifier la mémoire

Depuis SSH :

```bash
free -h
ps -eo pid,comm,rss,%mem --sort=-rss | head -n 15
df -h /
```

Si Chromium est lent :

- retire les flous CSS continus et les animations WebGL ;
- réduis la taille des pochettes côté application ;
- conserve uniquement les animations `opacity` et `transform` ;
- teste une résolution 1280 × 720 ;
- vérifie que le système n'utilise pas continuellement le swap.

---

# Phase 11 — Ajouter le bouton Power

Cette étape ne se fait qu'après validation complète du logiciel.

## 1. Configurer l'arrêt par GPIO3

```bash
sudo nano /boot/firmware/config.txt
```

Ajoute à la fin :

```ini
dtoverlay=gpio-shutdown
```

Puis :

```bash
sudo poweroff
```

Attends l'arrêt complet et débranche physiquement l'alimentation avant de câbler.

## 2. Câbler le bouton

Utilise un bouton poussoir momentané normalement ouvert :

| Fonction | GPIO BCM | Broche physique |
| --- | ---: | ---: |
| Power | GPIO3 | 5 |
| Masse | GND | 6 |

Le bouton relie simplement la broche 5 à la broche 6 pendant l'appui. S'il possède `COM`, `NO` et `NC`, utilise `COM` et `NO`.

## 3. Tester

1. rebranche l'alimentation ;
2. attends l'interface du jukebox ;
3. appuie brièvement sur Power ;
4. Linux doit s'arrêter proprement ;
5. après l'arrêt, appuie de nouveau ;
6. le Pi 2 doit redémarrer.

Le chargeur reste alimenté. Le Pi est en arrêt logiciel, pas déconnecté du secteur.

N'utilise pas `gpio-poweroff` : cet overlay empêcherait le réveil normal par GPIO3 sans circuit externe de coupure d'alimentation.

---

# Phase 12 — Réserver les GPIO des commandes et des LEDs

Le précédent brochage utilisait GPIO17 pour `Previous`. GPIO17 est maintenant réservé au contrôle général de l'éclairage LED. Le nouveau brochage conseillé est :

| Fonction | GPIO BCM | Broche physique |
| --- | ---: | ---: |
| Power | GPIO3 | 5 |
| Activation LEDs | GPIO17 | 11 |
| Previous | GPIO27 | 13 |
| Play/Pause | GPIO22 | 15 |
| Next | GPIO23 | 16 |
| Masse boutons | GND | 14 |

Chaque bouton de transport est un poussoir `NO` reliant son GPIO à GND. Les entrées doivent utiliser leurs résistances `pull-up` internes.

Avant le câblage, vérifie que l'application permet de configurer ces numéros. Si Fable avait codé l'ancien brochage en dur, il faudra le corriger.

Précautions :

- éteins et débranche le Pi avant de toucher aux broches ;
- ne relie jamais un bouton à 5 V ou 3,3 V ;
- GPIO3 reste exclusivement réservé au bouton Power ;
- GPIO17 reste exclusivement réservé à l'activation des LEDs ;
- plusieurs boutons peuvent partager une broche GND.

---

# Phase 13 — Faire suivre l'éclairage LED à l'état du jukebox

Cette phase concerne uniquement des LEDs basse tension avec un module MOSFET dont l'entrée accepte réellement un signal logique de 3,3 V.

Ne branche jamais un ruban LED directement sur le GPIO. Ne manipule pas de 230 V dans la borne.

Le principe matériel sera :

| Élément | Connexion |
| --- | --- |
| GPIO17, broche 11 | entrée `IN` ou `SIG` du module MOSFET |
| GND du Pi | masse logique du module |
| Alimentation LED | entrée puissance du module |
| Rubans/tubes | sortie puissance du module |

L'alimentation exacte et le câblage de puissance dépendront de la tension, de la longueur et de la consommation des LEDs. Attends d'avoir choisi les références avant de réaliser cette partie.

Pour préparer la commande logicielle marche/arrêt :

```bash
sudo apt install -y python3-gpiozero
sudo nano /usr/local/sbin/jukebox-led-power.py
```

Ajoute :

```python
#!/usr/bin/python3
import signal
import threading

from gpiozero import OutputDevice

stop_event = threading.Event()


def stop_service(signum, frame):
    stop_event.set()


signal.signal(signal.SIGTERM, stop_service)
signal.signal(signal.SIGINT, stop_service)

led_power = OutputDevice(17, active_high=True, initial_value=False)

try:
    led_power.on()
    stop_event.wait()
finally:
    led_power.off()
    led_power.close()
```

Puis :

```bash
sudo chmod 755 /usr/local/sbin/jukebox-led-power.py
sudo nano /etc/systemd/system/jukebox-led-power.service
```

```ini
[Unit]
Description=Jukebox LED master power
After=jukebox.service
Wants=jukebox.service

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'until /usr/bin/curl --max-time 2 --fail --silent http://127.0.0.1:4000/ >/dev/null; do sleep 1; done'
ExecStart=/usr/local/sbin/jukebox-led-power.py
Restart=on-failure
RestartSec=2
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
```

N'active le service qu'après avoir vérifié le module MOSFET et ajouté une résistance de rappel vers la masse si le module n'en contient pas :

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now jukebox-led-power
```

Le service allumera les LEDs lorsque Phoenix est prêt et placera GPIO17 à zéro pendant l'arrêt. Une résistance de rappel garantit l'extinction lorsque le GPIO redevient flottant après le `shutdown`.

Les rubans RGB analogiques ou adressables nécessiteront une commande supplémentaire pour les couleurs et les animations ; GPIO17 conservera alors le rôle de coupure générale.

---

# Phase 14 — Validation finale

## 1. Vérifier les services

```bash
systemctl is-active avahi-daemon
systemctl is-active mosquitto
systemctl is-active shairport-sync
systemctl is-active jukebox
curl --fail http://127.0.0.1:4000/ >/dev/null && echo 'Phoenix OK'
```

Si les LEDs sont installées :

```bash
systemctl is-active jukebox-led-power
```

## 2. Tester sans iPhone

- l'application apparaît automatiquement ;
- aucun bureau ni curseur ne reste visible ;
- l'écran ne s'éteint pas ;
- le Pi reste accessible en SSH ;
- `df -h /` montre plusieurs gigaoctets libres.

## 3. Tester AirPlay

- `Jukebox` apparaît sur l'iPhone ;
- le son sort du bon DAC ;
- titre, artiste et album s'affichent ;
- la pochette apparaît ;
- la progression avance ;
- pause et reprise sont visibles ;
- l'interface revient en attente après la session.

## 4. Tester les commandes physiques

- Previous ;
- Play/Pause ;
- Next ;
- aucun double déclenchement lors d'un appui.

## 5. Tester le cycle complet

- appui Power → extinction des LEDs ;
- arrêt Linux propre ;
- nouvel appui Power → démarrage ;
- démarrage automatique des services ;
- apparition de l'interface ;
- rallumage des LEDs lorsque Phoenix est prêt.

## 6. Surveiller les ressources pendant la musique

```bash
free -h
df -h /
top
```

Le système ne doit pas saturer continuellement la RAM, le swap ou le processeur.

---

# Diagnostic rapide

## `Jukebox` n'apparaît pas dans AirPlay

```bash
systemctl status shairport-sync --no-pager
systemctl status avahi-daemon --no-pager
avahi-browse -at
```

Vérifie :

- iPhone et Pi sur le même réseau local ;
- câble Ethernet actif ;
- absence de réseau invité ;
- isolation des clients désactivée sur la box.

## AirPlay apparaît mais aucun son ne sort

```bash
aplay -l
speaker-test -c 2 -t wav -D default
journalctl -u shairport-sync -n 100 --no-pager
```

Si `speaker-test` échoue, le problème concerne ALSA, le DAC ou l'amplificateur, pas AirPlay.

## Le son fonctionne mais l'écran ne se met pas à jour

```bash
shairport-sync -V
systemctl is-active mosquitto
mosquitto_sub -h 127.0.0.1 -v -t 'jukebox/shairport/#'
journalctl -u jukebox -n 100 --no-pager
```

Vérifie que Shairport et Phoenix utilisent exactement le même topic MQTT.

## Phoenix ne démarre pas

```bash
sudo systemctl status jukebox --no-pager
journalctl -u jukebox -n 150 --no-pager
sudo systemctl cat jukebox
```

Causes fréquentes :

- mauvais nom de release ;
- release compilée pour x86_64, ARM64 ou macOS au lieu d'ARMv7 ;
- `SECRET_KEY_BASE` manquant ;
- `DATABASE_URL` incorrect ;
- migrations non exécutées ;
- variables différentes de celles de `runtime.exs` ;
- permissions incorrectes dans `/opt/jukebox`.

## Chromium est lent ou plante

```bash
free -h
ps -eo pid,comm,rss,%mem --sort=-rss | head -n 15
journalctl -b --no-pager | grep -iE 'chromium|oom|killed'
```

Réduis d'abord les effets visuels et la résolution. N'installe pas un bureau complet et ne lance pas d'autre navigateur.

## La carte de 16 Go se remplit

```bash
df -h /
sudo du -xhd1 /var /home/jukebox /opt 2>/dev/null | sort -h
sudo journalctl --disk-usage
```

Puis :

```bash
sudo apt clean
sudo journalctl --vacuum-size=100M
```

Ne supprime rien dans `/var/lib/postgresql` manuellement.

## Les boutons ne fonctionnent pas

Vérifie d'abord les numéros configurés dans l'application. Le brochage retenu est désormais GPIO27, GPIO22 et GPIO23 ; GPIO17 est réservé aux LEDs.

## Les LEDs restent allumées après l'arrêt

- vérifie la résistance de rappel du module MOSFET ;
- vérifie que le module est actif à l'état haut ;
- vérifie que le service reçoit bien `SIGTERM` ;
- ne relie pas l'alimentation des LEDs aux broches 5 V du Pi.

## Le Pi affiche un éclair ou redémarre

Utilise une alimentation micro-USB 5 V stable avec un câble court. L'amplificateur et les LEDs doivent avoir leurs propres alimentations adaptées.

---

# Mise à jour de l'application

Pour une nouvelle version :

1. copie la source mise à jour ;
2. lance les tests ;
3. reconstruis la release sur une machine ARMv7 compatible ;
4. conserve une copie de la release précédente ;
5. remplace `/opt/jukebox` ;
6. exécute les migrations éventuelles ;
7. redémarre Phoenix ;
8. vérifie les logs, l'écran et AirPlay.

```bash
cd /home/jukebox/src/jukebox-app
mix test
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release --overwrite
sudo systemctl stop jukebox
sudo cp -a /opt/jukebox /opt/jukebox.previous
sudo rsync -a --delete _build/prod/rel/jukebox/ /opt/jukebox/
sudo chown -R jukebox:jukebox /opt/jukebox
sudo systemctl start jukebox
sudo systemctl status jukebox --no-pager
```

Adapte toujours le nom `jukebox` au vrai nom de la release.

Après plusieurs déploiements validés, supprime manuellement les anciennes copies devenues inutiles afin de préserver l'espace de la microSD.

---

# Sources techniques principales

- Raspberry Pi 2 Model B : https://www.raspberrypi.com/products/raspberry-pi-2-model-b/
- Images Raspberry Pi OS et espace requis : https://www.raspberrypi.com/software/operating-systems/
- Premier démarrage Raspberry Pi : https://www.raspberrypi.com/documentation/computers/getting-started.html
- Compilation Shairport Sync : https://github.com/mikebrady/shairport-sync/blob/master/BUILD.md
- AirPlay 2 et configuration minimale : https://github.com/mikebrady/shairport-sync/blob/master/AIRPLAY2.md
- MQTT et commandes Shairport : https://github.com/mikebrady/shairport-sync/blob/master/MQTT.md
- Exemple complet de configuration : https://github.com/mikebrady/shairport-sync/blob/master/scripts/shairport-sync.conf
- Releases Phoenix : https://hexdocs.pm/phoenix/releases.html
- Installation Elixir : https://elixir-lang.org/install.html
- Overlays `gpio-shutdown` et `gpio-poweroff` : https://github.com/raspberrypi/firmware/blob/master/boot/overlays/README
