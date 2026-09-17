# Installation complète du jukebox sur Raspberry Pi 3

Guide vérifié le 16 septembre 2026.

Ce guide part de zéro : on suppose que tu possèdes uniquement le Raspberry Pi, qu'une ancienne installation peut être présente sur sa carte microSD, et que l'application Phoenix/LiveView est terminée sur ton ordinateur.

L'architecture finale sera la suivante :

```text
iPhone / YouTube Music
        |
        | AirPlay classique
        v
Shairport Sync ----------------------> ALSA / DAC / amplificateur
        |
        | métadonnées + pochette via MQTT
        v
Mosquitto ---> application Phoenix ---> Chromium en mode kiosk ---> écran

boutons physiques ---> GPIO ---> application ---> MQTT remote ---> iPhone
```

Le Raspberry Pi devra démarrer directement sur l'écran du jukebox. L'écran restera purement passif : aucun tactile, aucune souris et aucune commande affichée à l'écran.

## Avant de commencer : ce qu'il te faut

### Matériel indispensable

- Raspberry Pi 3 B ou 3 B+ ;
- alimentation micro-USB stable de 5 V / 2,5 A ;
- nouvelle carte microSD de 32 Go minimum, de préférence A1 ou A2 ;
- lecteur de carte microSD pour ton Mac ;
- écran HDMI et câble HDMI standard ;
- connexion réseau, Ethernet de préférence pendant l'installation ;
- clavier et souris USB pour le premier démarrage, même si on travaillera ensuite principalement en SSH ;
- système audio : soit temporairement la sortie jack 3,5 mm du Pi, soit directement le DAC USB/HAT définitif ;
- amplificateur et enceintes actives ou passives selon ton montage.

### Pour plus tard, concernant les boutons

- quatre boutons poussoirs momentanés normalement ouverts : Power, Previous, Play/Pause et Next ;
- fils Dupont femelle-femelle pour un prototype ;
- éventuellement une petite breadboard ;
- aucun bouton ne doit être un interrupteur qui reste enclenché.

## Règle de sécurité importante

N'efface pas immédiatement l'ancienne carte microSD. Utilise une nouvelle carte pour l'installation. L'ancienne devient ainsi une sauvegarde physique et tu pourras toujours revenir en arrière.

L'écriture de Raspberry Pi OS par Raspberry Pi Imager efface entièrement la carte sélectionnée. Vérifie deux fois le nom et la capacité du support avant de cliquer sur `Write`.

---

# Phase 1 — Installer un système propre

## 1. Installer Raspberry Pi Imager sur le Mac

Télécharge Raspberry Pi Imager depuis le site officiel :

https://www.raspberrypi.com/software/

Installe puis ouvre l'application.

## 2. Préparer la nouvelle carte microSD

Insère la nouvelle carte dans le Mac, puis configure Imager ainsi :

1. `Choose Device` : sélectionne `Raspberry Pi 3`.
2. `Choose OS` : sélectionne `Raspberry Pi OS (64-bit)` avec bureau.
3. Ne choisis ni la version `Full`, qui contient beaucoup d'applications inutiles, ni la version `Lite`, car nous avons besoin d'un environnement graphique pour Chromium.
4. `Choose Storage` : sélectionne uniquement la nouvelle carte microSD.
5. Ouvre la personnalisation de l'OS.

Utilise les valeurs suivantes :

| Réglage | Valeur |
| --- | --- |
| Hostname | `jukebox` |
| Username | `jukebox` |
| Password | un mot de passe provisoire solide |
| Wi-Fi | ton SSID et son mot de passe |
| Wi-Fi country | `FR` |
| Timezone | `Europe/Paris` |
| Keyboard layout | `fr` |
| SSH | activé, authentification par mot de passe pour le premier démarrage |

Si tu utilises un Raspberry Pi 3 B non Plus, son Wi-Fi ne fonctionne qu'en 2,4 GHz. Un réseau exclusivement 5 GHz ne sera donc pas visible.

Lance l'écriture et attends la vérification complète de la carte.

## 3. Premier démarrage

Raspberry débranché :

1. insère la microSD ;
2. branche l'écran HDMI ;
3. branche le clavier et la souris ;
4. branche le câble Ethernet si possible ;
5. ne branche encore aucun bouton sur les GPIO ;
6. branche l'alimentation en dernier.

Le premier démarrage peut prendre plusieurs minutes.

## 4. Se connecter depuis le Mac

Sur le Mac, ouvre Terminal puis lance :

```bash
ssh jukebox@jukebox.local
```

Réponds `yes` à la première question puis saisis le mot de passe créé dans Imager.

Si `jukebox.local` ne répond pas, récupère l'adresse IP du Raspberry dans l'interface de ta box Internet, puis utilise par exemple :

```bash
ssh jukebox@192.168.1.42
```

## 5. Vérifier précisément la machine

Une fois connecté en SSH, exécute :

```bash
cat /proc/device-tree/model
echo
uname -m
cat /etc/os-release
free -h
df -h /
```

Résultats attendus :

- le modèle doit indiquer Raspberry Pi 3 B ou 3 B+ ;
- `uname -m` doit normalement afficher `aarch64` avec l'OS 64 bits ;
- la mémoire disponible sera proche de 1 Go ;
- la partition principale doit disposer de plusieurs gigaoctets libres.

Conserve cette sortie. Elle sera utile en cas de problème.

## 6. Mettre le système à jour

```bash
sudo apt update
sudo apt -y full-upgrade
sudo reboot
```

La connexion SSH se ferme. Attends environ deux minutes puis reconnecte-toi :

```bash
ssh jukebox@jukebox.local
```

## 7. Activer l'ouverture automatique de la session graphique

Lance :

```bash
sudo raspi-config
```

Dans les menus :

1. choisis `System Options` ;
2. choisis `Boot / Auto Login` ;
3. choisis `Desktop Autologin` ;
4. dans `Display Options`, désactive le screen blanking/la mise en veille de l'écran ;
5. quitte avec `Finish`.

Accepte le redémarrage si l'outil le propose.

---

# Phase 2 — Installer les outils système

Reconnecte-toi en SSH puis installe les outils de base :

```bash
sudo apt install -y \
  git curl ca-certificates rsync build-essential pkg-config \
  alsa-utils avahi-daemon avahi-utils \
  mosquitto mosquitto-clients chromium
```

Active les services réseau locaux :

```bash
sudo systemctl enable --now avahi-daemon
sudo systemctl enable --now mosquitto
```

Vérifie-les :

```bash
systemctl is-active avahi-daemon
systemctl is-active mosquitto
```

Chaque commande doit répondre `active`.

Mosquitto ne sera utilisé que localement par Shairport Sync et Phoenix. Il n'est pas nécessaire de l'exposer au réseau domestique ni de lui ajouter un compte utilisateur pour ce montage local.

---

# Phase 3 — Faire fonctionner le son avant AirPlay

Ne continue pas tant qu'un son de test Linux ne sort pas correctement. Cela permet de séparer un problème de DAC d'un problème AirPlay.

## 1. Lister les sorties audio

```bash
aplay -l
aplay -L
```

Avec le jack interne, tu verras une sortie liée au Raspberry Pi. Avec un DAC USB branché, une nouvelle carte audio doit apparaître.

## 2. Tester la sortie par défaut

Attention au volume de l'amplificateur : commence bas.

```bash
speaker-test -c 2 -t wav -D default
```

Tu dois entendre alternativement `Front Left` et `Front Right`. Arrête avec `Ctrl+C`.

## 3. Si aucun son ne sort

Ouvre le mixeur :

```bash
alsamixer
```

- `F6` permet de choisir la carte audio ;
- flèches gauche/droite : choisir un contrôle ;
- flèches haut/bas : modifier le volume ;
- `M` : activer/désactiver le mute ;
- `Esc` : quitter.

Sur Raspberry Pi OS Desktop, PipeWire peut gérer la sortie courante. Vérifie avec :

```bash
wpctl status
```

Si nécessaire, sélectionne graphiquement la bonne sortie audio depuis l'icône de volume du bureau. Recommence ensuite `speaker-test`.

Pour le premier prototype, la sortie jack est suffisante. Un DAC USB ou HAT sera préférable pour le jukebox définitif.

---

# Phase 4 — Installer Shairport Sync avec MQTT

Nous compilons Shairport Sync nous-mêmes, car le paquet précompilé de la distribution peut ne pas inclure l'interface MQTT dont l'application a besoin.

Nous choisissons AirPlay classique pour cette première version : il est suffisant pour une seule enceinte et son contrôle distant est plus mature dans Shairport Sync qu'en AirPlay 2.

## 1. Installer les dépendances

```bash
sudo apt install -y --no-install-recommends \
  autoconf automake libtool \
  libpopt-dev libconfig-dev libasound2-dev \
  libavahi-client-dev libssl-dev libsoxr-dev \
  libavutil-dev libavcodec-dev libavformat-dev \
  libmosquitto-dev
```

Vérifie le nom de la distribution :

```bash
. /etc/os-release
echo "$VERSION_CODENAME"
```

Si la réponse est `trixie` ou une version plus récente, teste d'abord l'installation de `systemd-dev` :

```bash
sudo apt install --dry-run --no-install-recommends systemd-dev
```

Lis le résumé. S'il ne propose pas de supprimer ou rétrograder des paquets système importants, installe-le :

```bash
sudo apt install -y --no-install-recommends systemd-dev
```

En cas de proposition de suppression importante, arrête-toi et conserve la sortie au lieu de confirmer.

## 2. Télécharger et compiler Shairport Sync

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
make -j2
sudo make install
```

Si `make -j2` est tué par manque de mémoire, relance simplement :

```bash
make -j1
sudo make install
```

## 3. Vérifier les fonctions compilées

```bash
shairport-sync -V
```

La chaîne affichée doit contenir au minimum des indications correspondant à ALSA, Avahi, metadata et MQTT. Si `mqtt` est absent, ne poursuis pas : la compilation n'a pas activé l'interface dont Phoenix a besoin.

## 4. Configurer Shairport Sync

Crée une sauvegarde du fichier installé :

```bash
sudo cp /etc/shairport-sync.conf /etc/shairport-sync.conf.original
sudo nano /etc/shairport-sync.conf
```

Remplace le contenu par cette configuration minimale :

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

Dans nano : `Ctrl+O`, `Entrée`, puis `Ctrl+X`.

## 5. Installer Shairport comme service utilisateur

Raspberry Pi OS Desktop utilise généralement PipeWire. La documentation de Shairport Sync demande alors un service utilisateur, démarré avec la session graphique, et non deux services concurrents.

Désactive une éventuelle instance système :

```bash
sudo systemctl disable --now shairport-sync 2>/dev/null || true
```

Puis :

```bash
cd /home/jukebox/src/shairport-sync
sh user-service-install.sh --dry-run
sh user-service-install.sh
systemctl --user enable --now shairport-sync
```

Vérifie :

```bash
systemctl --user status shairport-sync --no-pager
```

Le statut doit être `active (running)`.

Pour voir les logs en direct :

```bash
journalctl --user -u shairport-sync -f
```

Quitte les logs avec `Ctrl+C`.

## 6. Premier test AirPlay

L'iPhone et le Raspberry doivent être sur le même réseau local.

1. Lance une musique sur YouTube Music.
2. Ouvre le sélecteur de sortie AirPlay d'iOS.
3. Choisis `Jukebox`.
4. Vérifie que le son sort des enceintes.
5. Teste le volume depuis l'iPhone.

À ce stade, Phoenix n'intervient encore nulle part. Si le son fonctionne, la chaîne iPhone → AirPlay → Shairport Sync → audio est validée.

---

# Phase 5 — Vérifier les métadonnées et les commandes MQTT

## 1. Observer les événements lisibles

Dans une session SSH, lance :

```bash
mosquitto_sub -h 127.0.0.1 -v \
  -t 'jukebox/shairport/title' \
  -t 'jukebox/shairport/artist' \
  -t 'jukebox/shairport/album' \
  -t 'jukebox/shairport/play_start' \
  -t 'jukebox/shairport/play_end' \
  -t 'jukebox/shairport/active_start' \
  -t 'jukebox/shairport/active_end'
```

Lance ou change une chanson sur l'iPhone. Tu dois voir apparaître des lignes contenant le titre, l'artiste et les événements de lecture lorsque YouTube Music les fournit.

Ne t'inquiète pas si un champ manque : les applications iOS n'envoient pas toutes exactement les mêmes métadonnées.

## 2. Tester la commande Play/Pause inverse

Pendant qu'une musique joue :

```bash
mosquitto_pub -h 127.0.0.1 \
  -t 'jukebox/shairport/remote' \
  -m 'playpause'
```

Teste ensuite :

```bash
mosquitto_pub -h 127.0.0.1 \
  -t 'jukebox/shairport/remote' \
  -m 'nextitem'
```

```bash
mosquitto_pub -h 127.0.0.1 \
  -t 'jukebox/shairport/remote' \
  -m 'previtem'
```

Ces commandes doivent piloter le lecteur de l'iPhone si le client AirPlay et YouTube Music les acceptent. Si elles ne fonctionnent pas alors que l'audio et les métadonnées fonctionnent, le jukebox reste utilisable : l'iPhone demeure la télécommande principale.

---

# Phase 6 — Copier et identifier l'application Phoenix

Cette phase contient le seul point où les vrais fichiers du projet sont indispensables. Le cahier des charges ne permet pas de connaître le nom OTP réellement utilisé par Fable ni les versions choisies.

## 1. Copier le projet depuis le Mac

Sur le Mac, place-toi dans le dossier parent de l'application. Remplace `/chemin/vers/application-jukebox` par le chemin réel :

```bash
rsync -av \
  --exclude '_build' \
  --exclude 'deps' \
  --exclude 'assets/node_modules' \
  /chemin/vers/application-jukebox/ \
  jukebox@jukebox.local:/home/jukebox/src/jukebox-app/
```

Alternative si le projet est dans un dépôt Git accessible :

```bash
cd /home/jukebox/src
git clone URL_DU_DEPOT jukebox-app
```

N'inclus jamais de token GitHub directement dans l'URL de la commande.

## 2. Examiner ce que Fable a réellement produit

Sur le Raspberry :

```bash
cd /home/jukebox/src/jukebox-app
grep -n 'app:' mix.exs | head
grep -n 'elixir:' mix.exs | head
find . -maxdepth 2 -type f \( \
  -name '.tool-versions' -o \
  -name 'mise.toml' -o \
  -name 'Dockerfile' \
\) -print
grep -R 'System.get_env' config lib | sort
find ops docs -maxdepth 2 -type f -print 2>/dev/null | sort
```

### Point de contrôle obligatoire

Avant de continuer, conserve ou transmets les sorties de ces cinq commandes. Elles permettent de confirmer :

- le vrai nom de l'application et de sa release ;
- la version minimale d'Elixir ;
- la version d'Erlang/OTP éventuelle ;
- les variables d'environnement réellement reconnues ;
- l'éventuelle présence d'une base PostgreSQL ;
- les fichiers `systemd` ou Shairport déjà générés par Fable.

Les sections suivantes utilisent `jukebox` comme nom probable. Si `mix.exs` indique par exemple `app: :music_box`, il faudra remplacer le nom de binaire et de release par `music_box`.

---

# Phase 7 — Compiler une release Phoenix sur le Raspberry

Une release compilée sur macOS ne peut pas être copiée telle quelle sur Linux ARM. Il faut la compiler pour le même OS et la même architecture que le Raspberry. Le moyen le plus simple pour le premier déploiement consiste à compiler directement sur le Pi.

## 1. Installer Erlang et Elixir proposés par Raspberry Pi OS

```bash
sudo apt install -y erlang elixir
elixir --version
```

Compare la version affichée avec la contrainte `elixir:` de `mix.exs` et avec `.tool-versions` ou `mise.toml` s'ils existent.

Si la version installée ne respecte pas la contrainte du projet, arrête-toi ici. Ne modifie pas `mix.exs` uniquement pour contourner le problème : il faut installer la bonne paire Erlang/Elixir ou construire la release ARM64 dans un environnement compatible.

## 2. Installer Hex et Rebar

```bash
mix local.hex --force
mix local.rebar --force
```

## 3. Récupérer les dépendances et vérifier les tests

```bash
cd /home/jukebox/src/jukebox-app
mix deps.get
mix compile --warnings-as-errors
mix test
```

Ne déploie pas si les tests échouent.

## 4. Construire les assets et la release

```bash
cd /home/jukebox/src/jukebox-app
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release --overwrite
```

Liste le nom créé :

```bash
find _build/prod/rel -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
```

Supposons que le résultat soit `jukebox`. Vérifie le binaire :

```bash
ls -la _build/prod/rel/jukebox/bin
```

Si le nom est différent, utilise le vrai nom dans toutes les commandes suivantes.

## 5. Installer la release dans `/opt/jukebox`

```bash
sudo mkdir -p /opt/jukebox
sudo rsync -a \
  /home/jukebox/src/jukebox-app/_build/prod/rel/jukebox/ \
  /opt/jukebox/
sudo chown -R jukebox:jukebox /opt/jukebox
```

## 6. Créer le secret Phoenix

```bash
cd /home/jukebox/src/jukebox-app
mix phx.gen.secret
```

Copie la valeur obtenue. Ne la publie pas et ne la place pas dans Git.

## 7. Créer le fichier d'environnement

```bash
sudo nano /etc/jukebox.env
```

Base attendue :

```text
PHX_SERVER=true
PHX_HOST=localhost
PORT=4000
SECRET_KEY_BASE=COLLER_ICI_LE_SECRET_GENERE

JUKEBOX_METADATA_ADAPTER=mqtt
JUKEBOX_MQTT_HOST=127.0.0.1
JUKEBOX_MQTT_PORT=1883
JUKEBOX_MQTT_TOPIC=jukebox/shairport
JUKEBOX_REMOTE_CONTROL_ENABLED=true
JUKEBOX_IDLE_TIMEOUT_MS=5000
```

Remplace cette liste par les noms effectivement lus dans `config/runtime.exs` si Fable en a utilisé d'autres. S'il existe une variable de type `DATABASE_URL`, il faut vérifier si l'application a réellement conservé Ecto/PostgreSQL avant de continuer.

Protège le fichier :

```bash
sudo chown root:root /etc/jukebox.env
sudo chmod 600 /etc/jukebox.env
```

## 8. Créer le service Phoenix

```bash
sudo nano /etc/systemd/system/jukebox.service
```

Contenu :

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

Si la release ne contient pas `/opt/jukebox/bin/server`, remplace `ExecStart` par :

```ini
ExecStart=/opt/jukebox/bin/jukebox start
```

en utilisant toujours le véritable nom de la release.

## 9. Activer et tester Phoenix

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now jukebox
sudo systemctl status jukebox --no-pager
curl -I http://127.0.0.1:4000/
```

Le service doit être `active (running)` et `curl` doit recevoir une réponse HTTP.

En cas d'erreur :

```bash
journalctl -u jukebox -n 100 --no-pager
```

---

# Phase 8 — Lancer automatiquement Chromium en mode kiosk

## 1. Vérifier Chromium

```bash
command -v chromium
```

La commande doit afficher un chemin tel que `/usr/bin/chromium`.

## 2. Créer un lanceur résilient

```bash
mkdir -p /home/jukebox/bin
nano /home/jukebox/bin/start-jukebox-kiosk
```

Contenu :

```bash
#!/bin/bash

until curl --max-time 2 --fail --silent http://127.0.0.1:4000/ >/dev/null; do
  sleep 1
done

while true; do
  chromium \
    --kiosk \
    --noerrdialogs \
    --disable-infobars \
    --no-first-run \
    --disable-session-crashed-bubble \
    --disable-features=Translate \
    --autoplay-policy=no-user-gesture-required \
    http://127.0.0.1:4000/

  sleep 2
done
```

Rends-le exécutable :

```bash
chmod +x /home/jukebox/bin/start-jukebox-kiosk
```

## 3. Ajouter le lanceur à la session graphique

Sur les Raspberry Pi OS actuels, le bureau utilise Labwc :

```bash
mkdir -p /home/jukebox/.config/labwc
nano /home/jukebox/.config/labwc/autostart
```

Conserve les éventuelles lignes déjà présentes et ajoute à la fin :

```bash
/home/jukebox/bin/start-jukebox-kiosk &
```

## 4. Premier test de démarrage complet

```bash
sudo reboot
```

Le résultat attendu est :

1. démarrage de Linux ;
2. ouverture automatique de la session `jukebox` ;
3. lancement du service utilisateur Shairport Sync ;
4. lancement du service système Phoenix ;
5. Chromium attend que Phoenix réponde ;
6. Chromium s'ouvre directement en plein écran sur l'interface du jukebox.

Branche temporairement un clavier et utilise `Alt+F4` uniquement si tu dois fermer Chromium pendant les réglages. Le lanceur le rouvrira après deux secondes. Pour une maintenance normale, utilise SSH.

---

# Phase 9 — Ajouter le bouton Power du Raspberry Pi 3

Cette étape se fait uniquement après validation complète du logiciel.

## 1. Configurer Linux

Édite :

```bash
sudo nano /boot/firmware/config.txt
```

Ajoute à la fin :

```ini
dtoverlay=gpio-shutdown
```

Enregistre puis arrête complètement le Raspberry :

```bash
sudo poweroff
```

Attends que la LED d'activité ait cessé de clignoter, puis débranche physiquement l'alimentation.

## 2. Câbler le bouton Power

Utilise un bouton poussoir momentané normalement ouvert.

Sur le connecteur GPIO du Raspberry :

- broche physique 5 = GPIO3 ;
- broche physique 6 = GND, juste à côté.

Branchement :

```text
broche 5 / GPIO3 ---- bouton poussoir ---- broche 6 / GND
```

Si le bouton porte les mentions `COM`, `NO` et `NC`, utilise uniquement `COM` et `NO`.

Il n'y a aucune polarité pour ce contact : la couleur des deux fils n'a pas d'importance.

## 3. Tester

1. rebranche l'alimentation ;
2. le Raspberry démarre ;
3. attends l'écran du jukebox ;
4. appuie brièvement sur Power ;
5. Linux doit s'arrêter proprement ;
6. après arrêt complet, un nouvel appui doit réveiller le Pi 3.

Le chargeur reste électriquement branché après l'arrêt. Le bouton place le Pi en arrêt logiciel et ne coupe pas physiquement le 5 V.

---

# Phase 10 — Préparer les trois boutons de transport

Ne câble cette partie que si Fable a réellement fourni un adaptateur GPIO de production. Le cahier des charges autorisait également un adaptateur no-op ; il faut donc vérifier les modules et variables présents dans le projet.

## Brochage recommandé

| Commande | GPIO BCM | Broche physique |
| --- | ---: | ---: |
| Previous | GPIO17 | 11 |
| Play/Pause | GPIO27 | 13 |
| Next | GPIO22 | 15 |
| Masse commune | GND | 14 |

Chaque bouton poussoir relie son GPIO à la masse lors de l'appui :

```text
GPIO17 / pin 11 ---- bouton Previous ----+
GPIO27 / pin 13 ---- bouton Play/Pause --+---- GND / pin 14
GPIO22 / pin 15 ---- bouton Next --------+
```

Les entrées doivent être configurées avec une résistance de pull-up interne. Aucune résistance externe n'est alors nécessaire.

## Précautions

- éteins et débranche toujours le Raspberry avant de toucher aux broches ;
- ne branche jamais ces boutons sur une broche 5 V ou 3,3 V ;
- utilise des boutons `NO`, pas `NC` ;
- ne partage que la masse entre les boutons ;
- GPIO3 reste réservé au bouton Power ;
- ne configure pas les numéros de broches en dur à plusieurs endroits dans le code.

Ajoute l'utilisateur au groupe GPIO si l'adaptateur le nécessite :

```bash
sudo usermod -aG gpio jukebox
sudo reboot
```

La configuration exacte des variables GPIO doit venir de l'application réelle. N'invente pas des noms tels que `JUKEBOX_GPIO_PREVIOUS` s'ils ne sont pas lus dans `runtime.exs`.

---

# Phase 11 — Validation finale

Effectue les tests dans cet ordre.

## 1. État des services

```bash
systemctl is-active mosquitto
systemctl is-active jukebox
systemctl --user is-active shairport-sync
curl --fail http://127.0.0.1:4000/ >/dev/null && echo "Phoenix OK"
```

Résultat attendu : trois fois `active`, puis `Phoenix OK`.

## 2. Test sans iPhone

- l'écran démarre automatiquement ;
- l'écran de veille du jukebox est visible ;
- aucun bureau Linux, curseur ou barre Chromium ne reste visible ;
- l'écran ne se met pas en veille ;
- Phoenix redémarre automatiquement après un crash.

Pour tester le redémarrage de Phoenix :

```bash
sudo systemctl restart jukebox
```

Chromium doit retrouver l'application sans intervention.

## 3. Test AirPlay complet

- `Jukebox` apparaît dans AirPlay ;
- le son sort du bon appareil ;
- la pochette apparaît ;
- titre, artiste et album changent avec le morceau ;
- la progression avance ;
- pause/reprise s'affichent ;
- l'interface revient en attente lorsque la session AirPlay prend fin.

## 4. Test des commandes

- Previous ;
- Play/Pause ;
- Next ;
- appuis rapides sans double déclenchement parasite.

## 5. Test du cycle d'alimentation

- bouton Power → arrêt Linux propre ;
- bouton Power → démarrage ;
- retour automatique jusqu'à l'écran prêt pour AirPlay ;
- aucune souris ni clavier nécessaires.

---

# Diagnostic rapide

## `Jukebox` n'apparaît pas dans AirPlay

```bash
systemctl --user status shairport-sync --no-pager
systemctl status avahi-daemon --no-pager
avahi-browse -at
```

Vérifie aussi :

- iPhone et Raspberry sur le même réseau ;
- absence de réseau Wi-Fi invité ;
- option `AP isolation` ou `client isolation` désactivée sur la box ;
- pare-feu ne bloquant pas mDNS/Bonjour.

## AirPlay apparaît mais aucun son ne sort

```bash
aplay -l
speaker-test -c 2 -t wav -D default
journalctl --user -u shairport-sync -n 100 --no-pager
```

Si `speaker-test` échoue aussi, le problème est la sortie Linux/DAC, pas AirPlay.

## Le son fonctionne mais l'écran ne se met pas à jour

```bash
shairport-sync -V
systemctl is-active mosquitto
mosquitto_sub -h 127.0.0.1 -v -t 'jukebox/shairport/#'
journalctl -u jukebox -n 100 --no-pager
```

Vérifie que :

- `shairport-sync -V` contient `mqtt` ;
- Shairport publie sur `jukebox/shairport` ;
- Phoenix s'abonne au même topic ;
- les noms des variables d'environnement correspondent exactement à `runtime.exs`.

## Phoenix ne démarre pas

```bash
sudo systemctl status jukebox --no-pager
journalctl -u jukebox -n 150 --no-pager
sudo systemctl cat jukebox
```

Les causes fréquentes sont :

- mauvais nom de release dans `ExecStart` ;
- `SECRET_KEY_BASE` absent ;
- variable obligatoire manquante ;
- release compilée pour un autre OS ou une autre architecture ;
- dépendance à PostgreSQL restée active ;
- droits insuffisants sur `/opt/jukebox` ou le cache des pochettes.

## Chromium affiche une page d'erreur

```bash
curl -I http://127.0.0.1:4000/
systemctl status jukebox --no-pager
```

Le lanceur kiosk attend normalement Phoenix avant d'ouvrir Chromium. Si `curl` répond mais pas Chromium, vérifie :

```bash
command -v chromium
journalctl --user -b --no-pager | tail -n 100
```

## Les commandes Previous/Next ne contrôlent pas l'iPhone

Teste directement MQTT pendant la lecture :

```bash
mosquitto_pub -h 127.0.0.1 -t 'jukebox/shairport/remote' -m 'playpause'
```

Si cette commande ne fonctionne pas, le problème se situe avant les GPIO et Phoenix. Le contrôle DACP dépend aussi du comportement du client iOS. L'audio et l'affichage peuvent parfaitement fonctionner sans ce canal inverse.

## Le Pi affiche un éclair ou redémarre seul

L'alimentation est probablement insuffisante. Utilise une alimentation 5 V / 2,5 A de bonne qualité avec un câble court. Ne tente pas de compenser cela par un réglage logiciel.

---

# Mise à jour ultérieure de l'application

Pour déployer une nouvelle version :

1. copie la nouvelle source dans `/home/jukebox/src/jukebox-app` ;
2. lance les tests ;
3. reconstruis la release ;
4. arrête Phoenix ;
5. sauvegarde `/opt/jukebox` ;
6. copie la nouvelle release ;
7. redémarre Phoenix ;
8. vérifie les logs et l'interface.

Commandes générales :

```bash
cd /home/jukebox/src/jukebox-app
mix test
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release --overwrite
sudo systemctl stop jukebox
sudo cp -a /opt/jukebox /opt/jukebox.previous
sudo rsync -a _build/prod/rel/jukebox/ /opt/jukebox/
sudo chown -R jukebox:jukebox /opt/jukebox
sudo systemctl start jukebox
sudo systemctl status jukebox --no-pager
```

Ne supprime pas la version précédente avant d'avoir validé la nouvelle.

---

# Sources techniques principales

- Installation et premier démarrage Raspberry Pi : https://www.raspberrypi.com/documentation/computers/getting-started.html
- Kiosk Chromium officiel : https://www.raspberrypi.com/tutorials/how-to-use-a-raspberry-pi-in-kiosk-mode/
- Compilation actuelle de Shairport Sync : https://github.com/mikebrady/shairport-sync/blob/master/BUILD.md
- MQTT, métadonnées et commandes Shairport Sync : https://github.com/mikebrady/shairport-sync/blob/master/MQTT.md
- Configuration d'exemple Shairport Sync : https://github.com/mikebrady/shairport-sync/blob/master/scripts/shairport-sync.conf
- Releases Phoenix : https://phoenix.hexdocs.pm/releases.html
- Installation Elixir : https://elixir-lang.org/install/
- Overlay Raspberry Pi `gpio-shutdown` : https://github.com/raspberrypi/linux/blob/rpi-6.12.y/arch/arm/boot/dts/overlays/README
