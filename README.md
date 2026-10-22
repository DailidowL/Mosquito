# Mosquito – MQTT-Umgebung auf zwei Raspberry Pis

Prototyp einer MQTT-Umgebung mit der Brokersoftware **Eclipse Mosquitto** (LF07 / LS02).
Broker und Client laufen auf zwei getrennten Raspberry Pis mit unterschiedlichen
Betriebssystemen und tauschen Nachrichten in beide Richtungen aus.

Die Einrichtung übernimmt das PowerShell-Skript **`Setup-MqttPi.ps1`**: Es beschreibt die
SD-Karten und legt die Konfiguration darauf ab. Nach dem ersten Start richten sich die Pis
selbst ein (Docker, Mosquitto, feste IP-Adresse, Befehle `send` / `listen`).
Jedes Gerät hat gleichzeitig eine DHCP- und eine feste Adresse – die Umgebung läuft deshalb
am Router **und** am eigenen Switch, ohne dass etwas umgestellt werden muss.

| Gerät    | Betriebssystem                 | Rolle                            | Feste IP-Adresse |
|----------|--------------------------------|----------------------------------|------------------|
| brokerpi | Raspberry Pi OS Lite (64-Bit)  | MQTT-Broker, zugleich Client     | 192.168.50.1/24  |
| clientpi | Ubuntu Server 24.04 LTS        | MQTT-Client                      | 192.168.50.2/24  |
| Laptop   | Windows 11                     | Einrichtung, Fernzugriff per SSH | 192.168.50.10/24 |

---

## Voraussetzungen

**Hardware**

- 2 × Raspberry Pi (Modell 3 oder neuer), je eine microSD-Karte (ab 8 GB) und ein Netzteil
- 3 Netzwerkkabel, ein Router mit Internetzugang, ein Switch
- Windows-Laptop mit Kartenleser

**Auf dem Laptop**

- Administratorrechte
- [Raspberry Pi Imager](https://www.raspberrypi.com/software/) – wird vom Skript im Hintergrund aufgerufen, muss nur installiert sein
- [Git für Windows](https://git-scm.com/download/win) (alternativ ZIP-Download, siehe unten)
- Windows PowerShell 5.1 (in Windows enthalten)

**Eingesetzte Versionen**

| Software             | Version                                                |
|----------------------|--------------------------------------------------------|
| Raspberry Pi OS Lite | 64-Bit, Debian 13 „Trixie“, Stand 24.11.2025 (Broker)  |
| Ubuntu Server        | 24.04.5 LTS für Raspberry Pi, 64-Bit (Client)          |
| Eclipse Mosquitto    | Container-Image `eclipse-mosquitto:2`                  |
| Docker               | Pakete `docker.io` und `docker-compose`                |

---

## Schnellstart

### 1. PowerShell als Administrator öffnen

`Windows-Taste + R` → `powershell` eingeben → **`Strg + Umschalt + Enter`** → Rückfrage mit „Ja“ bestätigen.
In der Titelleiste steht dann „Administrator“. Alternativ: Rechtsklick auf das Startmenü → „Terminal (Administrator)“.

### 2. Skript herunterladen

```powershell
cd $HOME\Documents
mkdir MosquittoTest
cd .\MosquittoTest\
git clone https://github.com/MrRedstobe/Mosquito.git
cd .\Mosquito\
```

Ohne Git: auf GitHub „Code“ → „Download ZIP“, entpacken, in den Ordner wechseln und danach
`Unblock-File .\Setup-MqttPi.ps1` ausführen.

### 3. Skriptausführung für dieses Fenster erlauben

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

### 4. Skript dreimal ausführen

```powershell
.\Setup-MqttPi.ps1
```

| Durchlauf | Menüpunkt | Ergebnis                                                         | Dauer          |
|-----------|-----------|------------------------------------------------------------------|----------------|
| 1         | `1`       | SD-Karte für **brokerpi** (Raspberry Pi OS Lite + Mosquitto)      | 5 bis 20 Min.  |
| 2         | `2`       | SD-Karte für **clientpi** (Ubuntu Server + MQTT-Client)           | 5 bis 20 Min.  |
| 3         | `3`       | Laptop bekommt zusätzlich die Adresse 192.168.50.10 (keine SD-Karte) | unter 1 Min. |

Das Skript zeigt vor jeder Änderung an, **was verändert wird**, und fragt vor dem Löschen
einer Karte zweimal nach. Images werden zwischengespeichert (`%TEMP%\mqtt-pi-images`),
ein erneuter Durchlauf lädt sie nicht noch einmal.

> **Achtung:** Meldet Windows nach dem Schreiben, ein Laufwerk müsse formatiert werden,
> die Meldung mit „Abbrechen“ schließen – **auf keinen Fall formatieren**. Sie betrifft die
> Linux-Partition, die Windows nicht lesen kann.

### 5. Pis in Betrieb nehmen

1. Broker-Karte in brokerpi, Client-Karte in clientpi stecken.
2. Beide Pis per Kabel **mit dem Router** verbinden (beim ersten Start wird Internet gebraucht).
3. Netzteile anschließen und **5 bis 15 Minuten warten** – währenddessen nicht vom Strom trennen.
4. Prüfen:

```powershell
ssh pi@brokerpi.local      # Passwort: raspberry
mqtt-status                # Container "mosquitto" muss "Up" zeigen
```

Auf clientpi (`ssh pi@clientpi.local`) muss `mqtt-status` bei „Broker 192.168.50.1 erreichbar?“ **ja** melden.

---

## Parameter

| Parameter               | Wirkung                                                                  |
|-------------------------|--------------------------------------------------------------------------|
| `-Role broker`          | SD-Karte für brokerpi mit Raspberry Pi OS Lite und Mosquitto-Broker      |
| `-Role client`          | SD-Karte für clientpi mit Ubuntu Server und MQTT-Client                  |
| `-Role laptop`          | keine SD-Karte, sondern den Laptop für den Switch-Betrieb vorbereiten    |
| `-ImagePath <Pfad>`     | bereits heruntergeladenes Image (`.img.xz` oder `.img.gz`) verwenden     |
| `-SkipFlash`            | Karte nicht neu beschreiben, nur die Konfigurationsdateien ersetzen      |
| `-RemoveLaptopAddress`  | mit `-Role laptop`: die Zusatzadresse wieder entfernen                   |

```powershell
.\Setup-MqttPi.ps1 -Role client -ImagePath C:\Downloads\ubuntu.img.xz
.\Setup-MqttPi.ps1 -Role laptop -RemoveLaptopAddress
```

`-SkipFlash` wirkt nur, solange der Pi mit dieser Karte noch nicht gestartet wurde –
cloud-init wertet die Dateien nur beim allerersten Start aus.

---

## Bedienung: Publish und Subscribe

Anmeldung vom Laptop per SSH (Passwort `raspberry`, beenden mit `exit`):

| Ziel   | am Router               | am Switch               |
|--------|-------------------------|-------------------------|
| Broker | `ssh pi@brokerpi.local` | `ssh pi@192.168.50.1`   |
| Client | `ssh pi@clientpi.local` | `ssh pi@192.168.50.2`   |

| Befehl          | Funktion                                            | dahinter steht                         |
|-----------------|-----------------------------------------------------|----------------------------------------|
| `send "Text"`   | Nachricht veröffentlichen                           | `mosquitto_pub` mit QoS 1              |
| `listen`        | Nachrichten empfangen, bis `Strg + C` gedrückt wird | `mosquitto_sub` mit QoS 1              |
| `mqtt-status`   | Zustand des Geräts und des Brokers anzeigen         | `docker ps`, `hostname -I`, `ping`, `docker logs` |

Die Nachricht immer in **Anführungszeichen** setzen – bei mehreren Wörtern ohne
Anführungszeichen wertet `send` das erste Wort als Topic.

**Kommunikationstest** (zwei PowerShell-Fenster, eines je Pi):

| Schritt | Fenster 1: brokerpi        | Fenster 2: clientpi        | Ergebnis                         |
|---------|----------------------------|----------------------------|----------------------------------|
| 1       | `listen`                   |                            | wartet auf Nachrichten           |
| 2       |                            | `send "Hallo vom Client"`  | in Fenster 1: Hallo vom Client   |
| 3       | `Strg + C`                 | `listen`                   | Fenster 2 wartet auf Nachrichten |
| 4       | `send "Hallo vom Broker"`  |                            | in Fenster 2: Hallo vom Broker   |

### Betrieb am eigenen Switch

Beide Pis und den Laptop an den Switch anschließen – Reihenfolge egal, nichts umstellen:

```powershell
ping 192.168.50.1
ssh pi@192.168.50.1
ssh pi@192.168.50.2
```

### Broker verwalten (auf brokerpi)

| Aufgabe                       | Befehl                                                  |
|-------------------------------|---------------------------------------------------------|
| Protokoll ansehen / mitlesen  | `docker logs mosquitto` / `docker logs -f mosquitto`    |
| Broker neu starten            | `cd /opt/mqtt && docker compose restart`                |
| Broker anhalten / starten     | `docker compose down` / `docker compose up -d` (in `/opt/mqtt`) |
| Erstkonfiguration prüfen      | `cloud-init status --long`                              |

Der komplette Broker liegt in `/opt/mqtt` (`docker-compose.yml`, `config/`, `data/`, `log/`)
und lässt sich auf einen anderen Server kopieren und dort mit `docker compose up -d` starten.

---

## Zugangsdaten und Sicherheit

| Zweck                      | Wert                              | Hinweis                              |
|----------------------------|-----------------------------------|--------------------------------------|
| Anmeldung am Pi (SSH)      | Benutzer `pi`, Passwort `raspberry` | auf beiden Pis gleich              |
| Anmeldung am Broker (MQTT) | Benutzer `admin`, Passwort `admin`  | anonyme Verbindungen sind gesperrt |
| Basis-Topic                | `chat`                            | Nachrichten unter `chat/<Gerätename>` |

> Die Umgebung ist eine **Lernumgebung für ein abgeschlossenes Netz**. MQTT läuft
> unverschlüsselt über Port 1883, die Passwörter stehen im Klartext im Skript. Für einen
> echten Einsatz: TLS über Port 8883, eigene lange Passwörter und SSH-Schlüssel,
> `sudo` mit Passwortabfrage, Zugriffsliste (`acl_file`) und Firewall.

Adressen, Namen und Passwörter stehen gebündelt im Block `$Config` am Anfang des Skripts.
Nach einer Änderung **beide** Karten mit derselben Skriptfassung neu erstellen. Das Skript
prüft die Werte vor dem Start (gültige Adressen im selben Netz, keine Leer- oder
Sonderzeichen, die die Konfiguration auf den Pis zerstören würden).

---

## Was das Skript absichert

- **Kein falscher Datenträger:** Systemlaufwerke, leere Kartenleser und Platten ab 200 GB
  werden nie angeboten. Unmittelbar vor dem Schreiben prüft das Skript, ob unter der
  gewählten Nummer noch dieselbe Karte steckt – sonst bricht es ab, ohne etwas zu schreiben.
- **Kein kaputtes Image:** Downloads landen zuerst in einer `.part`-Datei und werden erst
  nach erfolgreicher Prüfung übernommen (Dateigröße, Dateiformat, Vollständigkeit, offizielle
  SHA-256-Prüfsumme). Kurze Netzaussetzer werden bis zu dreimal automatisch wiederholt.
  Ein beschädigtes Image im Zwischenspeicher wird erkannt und neu geladen.
- **Kein halber Schreibvorgang:** Ein bereits geöffnetes Imager-Fenster wird erkannt, der
  Laptop bleibt während Download und Schreiben wach, ein Abbruch mit `Strg + C` beendet
  auch den Imager.
- **Konfiguration sicher auf der Karte:** Jede Datei wird nach dem Schreiben zurückgelesen
  und verglichen, der Schreibpuffer wird vor dem Auswerfen geleert. Sind mehrere Karten mit
  gleicher Boot-Partition eingesteckt, rät das Skript nicht, sondern bricht ab.
- **Laptop-Adresse:** lässt sich auch bei abgezogenem Kabel wieder entfernen. Hängt sie
  noch an einem anderen Adapter, wird sie dort entfernt, damit sie nicht doppelt vergeben ist.

---

## Fehlerbehebung

| Meldung / Symptom | Ursache | Abhilfe |
|---|---|---|
| … Ausführung von Skripts … deaktiviert | Ausführungsrichtlinie | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` |
| Bitte PowerShell als Administrator starten … | keine Administratorrechte | PowerShell als Administrator öffnen |
| Raspberry Pi Imager nicht gefunden. | Imager nicht installiert | Imager installieren |
| Keine Wechseldatentraeger gefunden. | Karte oder Kartenleser nicht erkannt | Karte prüfen, anderen USB-Anschluss versuchen |
| Download fehlgeschlagen: … | kein Internet oder Adresse veraltet | Image von Hand laden, mit `-ImagePath` übergeben |
| Nicht genug freier Speicher fuer den Download … | Laufwerk mit `%TEMP%` voll | Platz schaffen oder Image woanders speichern und `-ImagePath` nutzen |
| Image-Datei unbrauchbar: … | Datei unvollständig oder kein Image | Image neu herunterladen |
| Offizielle Pruefsumme nicht abrufbar … (Hinweis) | Prüfsummen-Server nicht erreichbar | keine Aktion nötig, der Imager prüft beim Schreiben |
| Datentraeger … ist schreibgeschuetzt. | Schreibschutzschalter auf „Lock“ | Schalter am Kartenadapter umlegen |
| … steckt nicht mehr dieselbe Karte / … nicht mehr vorhanden | Karte während des Downloads getauscht oder abgezogen | Karte stecken lassen, Skript erneut starten |
| Der Raspberry Pi Imager ist bereits geoeffnet. | Imager-Fenster offen | Fenster schließen, Skript erneut starten |
| Schreiben fehlgeschlagen (Exit-Code …) | Karte defekt oder schreibgeschützt | Schreibschutz prüfen, andere Karte |
| Boot-Partition … nicht gefunden. | Partition nicht eingebunden | Karte ab- und wieder anstecken, `-SkipFlash` |
| Mehrere Boot-Partitionen … gefunden | mehrere vorbereitete Karten eingesteckt | nur die richtige Karte stecken lassen, `-SkipFlash` |
| Kein aktiver Netzwerkadapter gefunden. | kein Kabel oder Gegenstelle aus | Kabel und Switch prüfen |
| Dieses Windows erlaubt DHCP und feste Adresse nicht gleichzeitig. | ältere Windows-Version | Adresse von Hand setzen |
| DHCP wurde abgeschaltet. | Windows hat DHCP abgeschaltet | am Switch unkritisch, sonst `-RemoveLaptopAddress` |
| Ungueltige Werte im Block `$Config` … | Einstellung im Skript fehlerhaft | genannten Wert in `$Config` korrigieren |
| (unerwarteter Fehler in Zeile …) | unvorhergesehener Fehler | Meldung und Zeilennummer notieren und melden |
| Could not resolve hostname brokerpi.local | Pi noch nicht fertig oder Name nicht auflösbar | warten; am Switch `192.168.50.1` verwenden |
| REMOTE HOST IDENTIFICATION HAS CHANGED! | Karte wurde neu beschrieben | `ssh-keygen -R brokerpi.local` bzw. `ssh-keygen -R 192.168.50.1` |
| `mqtt-status` zeigt keinen Container | Einrichtung noch nicht fertig oder fehlgeschlagen | `cloud-init status --long`, ggf. `cd /opt/mqtt && sudo docker compose up -d` |
| not authorised | Benutzer oder Passwort falsch | `/etc/mqtt.env` prüfen |

Fehlersuche von unten nach oben: zuerst die Netzwerkverbindung (`ping`), dann der Broker
(`docker ps`), zuletzt Anmeldung und Topic.

---

## Projektstruktur

```
Setup-MqttPi.ps1        Einrichtungsskript (Laptop, als Administrator)
README.md
```