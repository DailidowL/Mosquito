<#
.SYNOPSIS
    Erstellt eine fertig konfigurierte SD-Karte fuer die MQTT-Umgebung (LF07 / LS02).

.DESCRIPTION
    Schreibt Raspberry Pi OS Lite (Broker) oder Ubuntu Server (Client) auf eine SD-Karte
    und legt die cloud-init-Dateien ab. Nach dem Einstecken in den Pi laeuft die komplette
    Einrichtung ohne weitere Eingriffe: Docker, Mosquitto, feste IP, send/listen.

    Die Karte bekommt DHCP UND eine feste IP-Adresse gleichzeitig. Dadurch funktioniert
    dieselbe Karte am Router (mit Internet fuer die Erstinstallation) und spaeter am
    eigenen Switch, ohne dass etwas umgestellt werden muss.

.PARAMETER Role
    broker  -> Raspberry Pi OS Lite 64-bit, Mosquitto-Broker, 192.168.50.1
    client  -> Ubuntu Server 24.04 LTS,     MQTT-Client,      192.168.50.2
    laptop  -> keine SD-Karte, sondern diesen Rechner fuer den Switch-Betrieb vorbereiten
    Ohne Angabe erscheint ein Auswahlmenue.

.PARAMETER RemoveLaptopAddress
    Nur zusammen mit -Role laptop: entfernt die feste Adresse wieder.

.PARAMETER ImagePath
    Pfad zu einer bereits heruntergeladenen .img.xz / .img.gz Datei.
    Ohne Angabe laedt das Skript das Image aus dem Internet.

.PARAMETER SkipFlash
    Ueberspringt das Schreiben des Images und legt nur die Konfigurationsdateien
    auf eine bereits beschriebene Karte. Nuetzlich zum Nachbessern.

.EXAMPLE
    .\Setup-MqttPi.ps1
    .\Setup-MqttPi.ps1 -Role broker
    .\Setup-MqttPi.ps1 -Role client -ImagePath C:\Downloads\ubuntu-24.04.img.xz
    .\Setup-MqttPi.ps1 -Role laptop

.NOTES
    Muss als Administrator ausgefuehrt werden.
    Benoetigt den Raspberry Pi Imager (raspberrypi.com/software).
#>

[CmdletBinding()]
param(
    [ValidateSet('broker', 'client', 'laptop')]
    [string]$Role,

    [string]$ImagePath,

    [switch]$SkipFlash,

    [switch]$RemoveLaptopAddress
)

$ErrorActionPreference = 'Stop'

# ============================================================================
#  EINSTELLUNGEN - hier bei Bedarf anpassen
# ============================================================================

$Config = @{
    BrokerIP     = '192.168.50.1'
    ClientIP     = '192.168.50.2'
    LaptopIP     = '192.168.50.10'
    Netmask      = '24'              # 24 entspricht 255.255.255.0
    BrokerName   = 'brokerpi'
    ClientName   = 'clientpi'
    LinuxUser    = 'pi'
    LinuxPass    = 'raspberry'
    MqttUser     = 'admin'
    MqttPass     = 'admin'
    Topic        = 'chat'
    Timezone     = 'Europe/Berlin'
}

# Download-Adressen. Falls eine Adresse nicht mehr stimmt, das Image von Hand
# laden und mit -ImagePath uebergeben.
$ImageUrls = @{
    broker = 'https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-11-24/2025-11-24-raspios-trixie-arm64-lite.img.xz'
    client = 'https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.5-preinstalled-server-arm64+raspi.img.xz'
}

$BootLabels = @{
    broker = 'bootfs'
    client = 'system-boot'
}

# ============================================================================
#  HILFSFUNKTIONEN
# ============================================================================

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Text)
    Write-Host "    $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "    $Text" -ForegroundColor Yellow
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Bitte PowerShell als Administrator starten (Rechtsklick auf das Startmenue -> Terminal (Administrator)).'
    }
}

function Find-RpiImager {
    $candidates = @(
        "$env:ProgramFiles\Raspberry Pi Imager\rpi-imager.exe",
        "${env:ProgramFiles(x86)}\Raspberry Pi Imager\rpi-imager.exe",
        "$env:LOCALAPPDATA\Programs\Raspberry Pi Imager\rpi-imager.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    $cmd = Get-Command rpi-imager.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'Raspberry Pi Imager nicht gefunden. Bitte von raspberrypi.com/software installieren.'
}

# Schreibt eine Textdatei ohne BOM und mit Unix-Zeilenenden.
# Beides ist fuer cloud-init zwingend - eine Datei mit BOM wird ignoriert.
function Write-UnixFile {
    param(
        [string]$Path,
        [string]$Content
    )
    $normalized = $Content -replace "`r`n", "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $normalized, $utf8NoBom)
}

function Select-TargetDisk {
    Write-Step 'Datentraeger auswaehlen'

    $disks = Get-Disk | Where-Object {
        $_.BusType -in @('USB', 'SD', 'MMC') -and $_.Size -lt 200GB
    } | Sort-Object Number

    if (-not $disks) {
        throw 'Keine Wechseldatentraeger gefunden. Steckt die SD-Karte im Kartenleser?'
    }

    $i = 0
    $table = foreach ($d in $disks) {
        $i++
        [PSCustomObject]@{
            Nr      = $i
            Disk    = $d.Number
            Groesse = '{0:N1} GB' -f ($d.Size / 1GB)
            Modell  = $d.FriendlyName
            Bus     = $d.BusType
        }
    }
    $table | Format-Table -AutoSize | Out-String | Write-Host

    Write-Warn 'ACHTUNG: Der gewaehlte Datentraeger wird vollstaendig geloescht.'
    $choice = Read-Host 'Nummer eingeben (Abbruch mit Enter)'
    if ([string]::IsNullOrWhiteSpace($choice)) { throw 'Abgebrochen.' }

    $idx = 0
    if (-not [int]::TryParse($choice, [ref]$idx) -or $idx -lt 1 -or $idx -gt @($disks).Count) {
        throw "Ungueltige Auswahl: $choice"
    }

    $selected = @($disks)[$idx - 1]
    $sizeGb = '{0:N1}' -f ($selected.Size / 1GB)
    Write-Host ''
    Write-Warn "Gewaehlt: Datentraeger $($selected.Number) - $($selected.FriendlyName) - $sizeGb GB"
    $confirm = Read-Host "Wirklich loeschen und beschreiben? (ja/nein)"
    if ($confirm -notin @('ja', 'j', 'yes', 'y')) { throw 'Abgebrochen.' }

    return $selected
}

function Get-ImageFile {
    param([string]$SelectedRole)

    if ($ImagePath) {
        if (-not (Test-Path $ImagePath)) { throw "Datei nicht gefunden: $ImagePath" }
        Write-Ok "Verwende vorhandenes Image: $ImagePath"
        return (Resolve-Path $ImagePath).Path
    }

    $url = $ImageUrls[$SelectedRole]
    $cacheDir = Join-Path $env:TEMP 'mqtt-pi-images'
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    $target = Join-Path $cacheDir (Split-Path $url -Leaf)

    if (Test-Path $target) {
        Write-Ok "Image bereits vorhanden: $target"
        return $target
    }

    Write-Step 'Image herunterladen'
    Write-Host "    Quelle: $url"
    Write-Host '    Das kann je nach Verbindung einige Minuten dauern.'

    try {
        # Fortschrittsanzeige aus: Mit Anzeige ist Invoke-WebRequest in
        # Windows PowerShell 5.1 bei grossen Dateien um ein Vielfaches langsamer.
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $target -UseBasicParsing
    }
    catch {
        if (Test-Path $target) { Remove-Item $target -Force }
        throw @"
Download fehlgeschlagen: $($_.Exception.Message)

Die Adresse im Skript ist moeglicherweise veraltet. Bitte das Image von Hand laden:
  broker -> raspberrypi.com/software/operating-systems (Raspberry Pi OS Lite, 64-bit)
  client -> ubuntu.com/download/raspberry-pi (Ubuntu Server 24.04 LTS, 64-bit)
und danach mit -ImagePath uebergeben.
"@
    }

    Write-Ok "Gespeichert: $target"
    return $target
}

function Invoke-Flash {
    param(
        [string]$Imager,
        [string]$Image,
        [int]$DiskNumber
    )

    Write-Step 'Image auf die Karte schreiben'
    Write-Host '    Dies dauert je nach Karte 3 bis 15 Minuten. Bitte nicht abziehen.'

    $device = "\\.\PHYSICALDRIVE$DiskNumber"
    $proc = Start-Process -FilePath $Imager `
                          -ArgumentList @('--cli', "`"$Image`"", "`"$device`"") `
                          -Wait -PassThru -NoNewWindow

    if ($proc.ExitCode -ne 0) {
        throw "Schreiben fehlgeschlagen (Exit-Code $($proc.ExitCode)). Karte pruefen oder andere Karte verwenden."
    }
    Write-Ok 'Image geschrieben und geprueft.'
}

function Wait-BootPartition {
    param(
        [string]$Label,
        [int]$TimeoutSeconds = 120
    )

    Write-Step "Boot-Partition '$Label' suchen"

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $vol = Get-Volume -ErrorAction SilentlyContinue |
               Where-Object { $_.FileSystemLabel -eq $Label -and $_.DriveLetter }
        if ($vol) {
            $path = "$($vol.DriveLetter):"
            Write-Ok "Gefunden unter $path"
            return $path
        }

        # Partition ohne Laufwerksbuchstaben: einen zuweisen
        $noLetter = Get-Partition -ErrorAction SilentlyContinue |
                    Where-Object { -not $_.DriveLetter -and $_.Size -lt 2GB -and $_.Size -gt 100MB }
        foreach ($p in $noLetter) {
            try {
                $v = Get-Volume -Partition $p -ErrorAction SilentlyContinue
                if ($v -and $v.FileSystemLabel -eq $Label) {
                    $free = [char[]](68..90) | Where-Object {
                        -not (Get-PSDrive -Name $_ -ErrorAction SilentlyContinue)
                    } | Select-Object -First 1
                    Set-Partition -InputObject $p -NewDriveLetter $free
                    Write-Ok "Laufwerksbuchstabe ${free}: zugewiesen"
                    return "${free}:"
                }
            }
            catch { }
        }

        Start-Sleep -Seconds 3
    }

    throw "Boot-Partition '$Label' nicht gefunden. Karte kurz abziehen, wieder einstecken und das Skript mit -SkipFlash erneut starten."
}

# ============================================================================
#  KONFIGURATIONSDATEIEN
# ============================================================================

#
#  WICHTIG: Die folgenden Texte sind PowerShell-Here-Strings (@" ... "@). Darin wird
#  jedes $ als PowerShell-Variable ausgewertet. Ein $, das als $ in der Linux-Datei
#  landen soll, muss mit Backtick geschrieben werden: `$
#  Ein Backslash \$ wirkt in PowerShell NICHT als Escape.

function Get-BrokerUserData {
    $ip = $Config.BrokerIP
    return @"
#cloud-config
hostname: $($Config.BrokerName)
manage_etc_hosts: true
timezone: $($Config.Timezone)

users:
  - name: $($Config.LinuxUser)
    groups: users,adm,sudo,dialout,video,plugdev,docker
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: $($Config.LinuxPass)
    sudo: ALL=(ALL) NOPASSWD:ALL

enable_ssh: true
ssh_pwauth: true

apt:
  conf: |
    Acquire { Check-Date "false"; };

package_update: true
packages:
  - docker.io
  - docker-compose
  - avahi-daemon

write_files:
  - path: /opt/mqtt/docker-compose.yml
    permissions: '0644'
    content: |
      services:
        mosquitto:
          image: eclipse-mosquitto:2
          container_name: mosquitto
          restart: unless-stopped
          ports:
            - "1883:1883"
          volumes:
            - ./config:/mosquitto/config
            - ./data:/mosquitto/data
            - ./log:/mosquitto/log

  - path: /opt/mqtt/config/mosquitto.conf
    permissions: '0644'
    content: |
      listener 1883
      allow_anonymous false
      password_file /mosquitto/config/passwd
      persistence true
      persistence_location /mosquitto/data/
      log_dest stdout

  - path: /etc/mqtt.env
    permissions: '0644'
    content: |
      BROKER=localhost
      MQTT_USER=$($Config.MqttUser)
      MQTT_PASS=$($Config.MqttPass)
      TOPIC=$($Config.Topic)

  - path: /usr/local/bin/send
    permissions: '0755'
    content: |
      #!/bin/sh
      . /etc/mqtt.env
      if [ `$# -ge 2 ]; then SUB="`$1"; shift; else SUB="`$(hostname)"; fi
      [ `$# -eq 0 ] && { echo 'Benutzung: send "Nachricht"  oder  send thema "Nachricht"'; exit 1; }
      exec docker exec mosquitto mosquitto_pub -h localhost \
        -u "`$MQTT_USER" -P "`$MQTT_PASS" -q 1 -t "`$TOPIC/`$SUB" -m "`$*"

  - path: /usr/local/bin/listen
    permissions: '0755'
    content: |
      #!/bin/sh
      . /etc/mqtt.env
      SUB="`${1:-#}"
      echo "Empfange `$TOPIC/`$SUB  (Strg+C beendet)"
      exec docker exec -it mosquitto mosquitto_sub -h localhost \
        -u "`$MQTT_USER" -P "`$MQTT_PASS" -q 1 -v -t "`$TOPIC/`$SUB"

  - path: /usr/local/bin/mqtt-status
    permissions: '0755'
    content: |
      #!/bin/sh
      echo "=== Container ==="
      docker ps --filter name=mosquitto --format '{{.Names}}  {{.Status}}  {{.Ports}}'
      echo
      echo "=== Adressen ==="
      hostname -I
      echo
      echo "=== Letzte Protokollzeilen ==="
      docker logs --tail 15 mosquitto 2>&1

runcmd:
  - [ mkdir, -p, /opt/mqtt/data, /opt/mqtt/log ]
  - [ systemctl, enable, --now, docker ]
  - [ sh, -c, 'docker run --rm -v /opt/mqtt/config:/mosquitto/config eclipse-mosquitto:2 mosquitto_passwd -c -b /mosquitto/config/passwd $($Config.MqttUser) $($Config.MqttPass)' ]
  - [ sh, -c, 'chown -R 1883:1883 /opt/mqtt/config /opt/mqtt/data /opt/mqtt/log && chmod 0700 /opt/mqtt/config/passwd' ]
  - [ sh, -c, 'cd /opt/mqtt && docker compose up -d || docker-compose up -d' ]
  - [ systemctl, enable, --now, avahi-daemon ]
  - [ sh, -c, 'echo "Broker bereit auf $ip und per DHCP" > /etc/motd' ]

final_message: "Broker fertig eingerichtet nach `$UPTIME Sekunden."
"@
}

function Get-ClientUserData {
    return @"
#cloud-config
hostname: $($Config.ClientName)
manage_etc_hosts: true
timezone: $($Config.Timezone)

users:
  - name: $($Config.LinuxUser)
    groups: users,adm,sudo,docker
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: $($Config.LinuxPass)
    sudo: ALL=(ALL) NOPASSWD:ALL

ssh_pwauth: true

package_update: true
packages:
  - docker.io
  - avahi-daemon
  - libnss-mdns

write_files:
  - path: /etc/mqtt.env
    permissions: '0644'
    content: |
      BROKER=$($Config.BrokerIP)
      MQTT_USER=$($Config.MqttUser)
      MQTT_PASS=$($Config.MqttPass)
      TOPIC=$($Config.Topic)

  - path: /usr/local/bin/send
    permissions: '0755'
    content: |
      #!/bin/sh
      . /etc/mqtt.env
      if [ `$# -ge 2 ]; then SUB="`$1"; shift; else SUB="`$(hostname)"; fi
      [ `$# -eq 0 ] && { echo 'Benutzung: send "Nachricht"  oder  send thema "Nachricht"'; exit 1; }
      exec docker run --rm --network host eclipse-mosquitto:2 mosquitto_pub \
        -h "`$BROKER" -p 1883 -u "`$MQTT_USER" -P "`$MQTT_PASS" \
        -q 1 -t "`$TOPIC/`$SUB" -m "`$*"

  - path: /usr/local/bin/listen
    permissions: '0755'
    content: |
      #!/bin/sh
      . /etc/mqtt.env
      SUB="`${1:-#}"
      echo "Empfange `$TOPIC/`$SUB von `$BROKER  (Strg+C beendet)"
      exec docker run --rm -it --network host eclipse-mosquitto:2 mosquitto_sub \
        -h "`$BROKER" -p 1883 -u "`$MQTT_USER" -P "`$MQTT_PASS" \
        -q 1 -v -t "`$TOPIC/`$SUB"

  - path: /usr/local/bin/mqtt-status
    permissions: '0755'
    content: |
      #!/bin/sh
      . /etc/mqtt.env
      echo "=== Adressen ==="
      hostname -I
      echo
      echo "=== Broker `$BROKER erreichbar? ==="
      ping -c 2 -W 2 "`$BROKER" > /dev/null 2>&1 && echo "ja" || echo "NEIN"
      echo
      echo "=== Mosquitto-Image vorhanden? ==="
      docker image ls eclipse-mosquitto:2 --format '{{.Repository}}:{{.Tag}}  {{.Size}}'

runcmd:
  - [ systemctl, enable, --now, docker ]
  - [ systemctl, enable, --now, avahi-daemon ]
  - [ docker, pull, 'eclipse-mosquitto:2' ]
  - [ sh, -c, 'echo "Client bereit. Broker: $($Config.BrokerIP)" > /etc/motd' ]

final_message: "Client fertig eingerichtet nach `$UPTIME Sekunden."
"@
}

function Get-NetworkConfig {
    param([string]$SelectedRole)

    $ip = if ($SelectedRole -eq 'broker') { $Config.BrokerIP } else { $Config.ClientIP }
    $addr = "$ip/$($Config.Netmask)"

    # DHCP und feste Adresse gleichzeitig:
    # Am Router holt sich der Pi zusaetzlich eine Adresse und hat Internet fuer die
    # Installation. Am Switch bleibt die feste Adresse uebrig. Keine Umstellung noetig.
    if ($SelectedRole -eq 'broker') {
        # Raspberry Pi OS erwartet den aeusseren Schluessel "network:"
        return @"
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    eth0:
      dhcp4: true
      dhcp4-overrides:
        use-dns: true
      addresses: [$addr]
      optional: true
"@
    }
    else {
        # Ubuntu erwartet das Format ohne "network:"
        return @"
version: 2
ethernets:
  eth0:
    dhcp4: true
    dhcp4-overrides:
      use-dns: true
    addresses: [$addr]
    optional: true
"@
    }
}

# ============================================================================
#  LAPTOP-NETZWERK
# ============================================================================

# Fuegt dem Netzwerkadapter eine zweite, feste Adresse hinzu, ohne DHCP abzuschalten.
# Dasselbe Prinzip wie bei den Pis: am Router zaehlt die DHCP-Adresse, am Switch
# die feste. Kein Umschalten mehr noetig.
function Set-LaptopAddress {
    param([switch]$Remove)

    Write-Step 'Netzwerkadapter des Laptops'

    $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop |
                  Where-Object { $_.Status -eq 'Up' } |
                  Sort-Object -Property @{ Expression = { $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN' } }, Name)

    if (-not $adapters) {
        throw 'Kein aktiver Netzwerkadapter gefunden. Netzwerkkabel eingesteckt?'
    }

    if ($adapters.Count -eq 1) {
        $adapter = $adapters[0]
        Write-Ok "Adapter: $($adapter.Name) - $($adapter.InterfaceDescription)"
    }
    else {
        $i = 0
        $table = foreach ($a in $adapters) {
            $i++
            [PSCustomObject]@{
                Nr          = $i
                Name        = $a.Name
                Beschreibung = $a.InterfaceDescription
                Tempo       = $a.LinkSpeed
            }
        }
        $table | Format-Table -AutoSize | Out-String | Write-Host
        Write-Host '    Gemeint ist der Anschluss, an dem das Netzwerkkabel zum Switch haengt.'
        $sel = Read-Host '    Nummer eingeben'
        $idx = 0
        if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $adapters.Count) {
            throw "Ungueltige Auswahl: $sel"
        }
        $adapter = $adapters[$idx - 1]
    }

    $existing = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex `
                                 -IPAddress $Config.LaptopIP `
                                 -ErrorAction SilentlyContinue

    if ($Remove) {
        if ($existing) {
            Remove-NetIPAddress -InterfaceIndex $adapter.ifIndex `
                                -IPAddress $Config.LaptopIP -Confirm:$false
            Write-Ok "Adresse $($Config.LaptopIP) entfernt."
            $iface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4
            if ($iface.Dhcp -ne 'Enabled') {
                Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Enabled
                Write-Ok 'DHCP wieder eingeschaltet.'
            }
        }
        else {
            Write-Warn "Adresse $($Config.LaptopIP) war nicht gesetzt."
        }
        return
    }

    # Reihenfolge ist wichtig:
    # 1. DHCP einschalten, falls aus. Das Einschalten loescht vorhandene feste Adressen,
    #    deshalb muss es VOR dem Hinzufuegen passieren.
    # 2. Koexistenz von DHCP und fester Adresse erlauben. Ohne diese Einstellung schaltet
    #    New-NetIPAddress DHCP automatisch ab.
    # 3. Feste Adresse hinzufuegen.
    $iface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4
    if ($iface.Dhcp -ne 'Enabled') {
        Write-Warn 'DHCP war abgeschaltet und wird eingeschaltet.'
        Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Enabled
        Start-Sleep -Seconds 3
        $existing = $null
    }

    $null = & netsh interface ipv4 set interface interface="$($adapter.ifIndex)" dhcpstaticipcoexistence=enabled
    if ($LASTEXITCODE -ne 0) {
        throw 'Dieses Windows erlaubt DHCP und feste Adresse nicht gleichzeitig. Bitte die Adresse von Hand setzen (siehe Technische Doku).'
    }
    Write-Ok 'DHCP und feste Adresse duerfen gleichzeitig bestehen.'

    if ($existing) {
        Write-Ok "Adresse $($Config.LaptopIP) ist bereits gesetzt."
    }
    else {
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex `
                         -IPAddress $Config.LaptopIP `
                         -PrefixLength ([int]$Config.Netmask) `
                         -ErrorAction Stop | Out-Null
        Write-Ok "Adresse $($Config.LaptopIP)/$($Config.Netmask) hinzugefuegt."
    }

    # Kontrolle: DHCP muss weiterhin aktiv sein
    $iface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4
    if ($iface.Dhcp -eq 'Enabled') {
        Write-Ok 'DHCP bleibt aktiv.'
    }
    else {
        Write-Warn 'DHCP wurde abgeschaltet. Am Switch funktioniert alles, am Router hat der Laptop so kein Internet.'
        Write-Warn "Rueckgaengig: .\Setup-MqttPi.ps1 -Role laptop -RemoveLaptopAddress"
    }

    Write-Host ''
    Write-Host '    Adressen dieses Adapters:'
    Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 |
        Select-Object IPAddress, PrefixLength, PrefixOrigin |
        Format-Table -AutoSize | Out-String | Write-Host
}

# ============================================================================
#  HAUPTPROGRAMM
# ============================================================================

try {
    Write-Host ''
    Write-Host '  MQTT-Umgebung - SD-Karte erstellen' -ForegroundColor White
    Write-Host '  LF07 / LS02 - Mosquitto auf Raspberry Pi' -ForegroundColor DarkGray
    Write-Host '  ----------------------------------------' -ForegroundColor DarkGray

    Assert-Admin

    # --- Rolle waehlen ---
    if (-not $Role) {
        Write-Host ''
        Write-Host '  Welche Karte soll erstellt werden?'
        Write-Host ''
        Write-Host "  [1] Broker  - Raspberry Pi OS Lite, Mosquitto, $($Config.BrokerIP)"
        Write-Host "  [2] Client  - Ubuntu Server 24.04,  MQTT-Client, $($Config.ClientIP)"
        Write-Host "  [3] Laptop  - diesen Rechner fuer den Switch-Betrieb vorbereiten"
        Write-Host ''
        $sel = Read-Host '  Auswahl (1, 2 oder 3)'
        switch ($sel) {
            '1' { $Role = 'broker' }
            '2' { $Role = 'client' }
            '3' { $Role = 'laptop' }
            default { throw "Ungueltige Auswahl: $sel" }
        }
    }

    # --- Laptop: nur Netzwerk, keine SD-Karte ---
    if ($Role -eq 'laptop') {
        Set-LaptopAddress -Remove:$RemoveLaptopAddress

        if ($RemoveLaptopAddress) {
            Write-Host ''
            Write-Host '  Feste Adresse entfernt. Der Laptop nutzt jetzt nur noch DHCP.' -ForegroundColor Green
            Write-Host ''
            exit 0
        }

        Write-Host ''
        Write-Host '  ----------------------------------------' -ForegroundColor DarkGray
        Write-Host '  FERTIG' -ForegroundColor Green
        Write-Host ''
        Write-Host "  Der Laptop hat jetzt zwei Adressen: eine per DHCP vom Router"
        Write-Host "  und fest $($Config.LaptopIP). Beide Netze funktionieren ohne Umschalten."
        Write-Host ''
        Write-Host "  Test am Switch:   ping $($Config.BrokerIP)"
        Write-Host "  Anmelden:         ssh $($Config.LinuxUser)@$($Config.BrokerIP)"
        Write-Host ''
        Write-Host '  Rueckgaengig:     .\Setup-MqttPi.ps1 -Role laptop -RemoveLaptopAddress'
        Write-Host ''
        exit 0
    }

    $hostName = if ($Role -eq 'broker') { $Config.BrokerName } else { $Config.ClientName }
    $ipAddr   = if ($Role -eq 'broker') { $Config.BrokerIP }   else { $Config.ClientIP }
    $label    = $BootLabels[$Role]

    Write-Host ''
    Write-Ok "Rolle:    $Role"
    Write-Ok "Hostname: $hostName"
    Write-Ok "Feste IP: $ipAddr"

    # --- Karte beschreiben ---
    if (-not $SkipFlash) {
        $imager = Find-RpiImager
        Write-Ok "Imager:   $imager"

        $disk  = Select-TargetDisk
        $image = Get-ImageFile -SelectedRole $Role

        Invoke-Flash -Imager $imager -Image $image -DiskNumber $disk.Number
    }
    else {
        Write-Warn 'Schreiben uebersprungen (-SkipFlash).'
    }

    # --- Konfiguration ablegen ---
    $bootDrive = Wait-BootPartition -Label $label

    Write-Step 'Konfigurationsdateien schreiben'

    $userData = if ($Role -eq 'broker') { Get-BrokerUserData } else { Get-ClientUserData }
    $netConf  = Get-NetworkConfig -SelectedRole $Role

    Write-UnixFile -Path (Join-Path $bootDrive 'user-data')      -Content $userData
    Write-Ok 'user-data geschrieben'

    Write-UnixFile -Path (Join-Path $bootDrive 'network-config') -Content $netConf
    Write-Ok 'network-config geschrieben'

    # meta-data muss vorhanden sein, darf aber leer bleiben
    $metaPath = Join-Path $bootDrive 'meta-data'
    if (-not (Test-Path $metaPath)) {
        Write-UnixFile -Path $metaPath -Content "instance-id: $hostName`n"
        Write-Ok 'meta-data angelegt'
    }

    # Raspberry Pi OS: leere Datei "ssh" aktiviert SSH auch ohne cloud-init
    if ($Role -eq 'broker') {
        Write-UnixFile -Path (Join-Path $bootDrive 'ssh') -Content ''
        Write-Ok 'SSH freigeschaltet'
    }

    # --- Karte auswerfen ---
    Write-Step 'Karte auswerfen'
    try {
        $shell = New-Object -ComObject Shell.Application
        $shell.Namespace(17).ParseName($bootDrive).InvokeVerb('Eject')
        Write-Ok 'Ausgeworfen. Karte kann entnommen werden.'
    }
    catch {
        Write-Warn 'Automatisches Auswerfen fehlgeschlagen. Bitte ueber den Explorer auswerfen.'
    }

    # --- Abschluss ---
    Write-Host ''
    Write-Host '  ----------------------------------------' -ForegroundColor DarkGray
    Write-Host '  FERTIG' -ForegroundColor Green
    Write-Host ''
    Write-Host "  1. Karte in den Pi stecken ($hostName)"
    Write-Host '  2. Netzwerkkabel an den Router (Internet wird fuer die Installation gebraucht)'
    Write-Host '  3. Strom anschliessen, danach 5 bis 15 Minuten warten'
    Write-Host ''
    Write-Host "  4. Pruefen am Router:  ssh $($Config.LinuxUser)@$hostName.local     Passwort: $($Config.LinuxPass)"
    Write-Host "     Pruefen am Switch:  ssh $($Config.LinuxUser)@$ipAddr"
    Write-Host '     Danach auf dem Pi:  mqtt-status'
    Write-Host ''
    if ($Role -eq 'broker') {
        Write-Host '  Danach die zweite Karte erstellen:  .\Setup-MqttPi.ps1 -Role client'
    }
    else {
        Write-Host '  Test:  auf brokerpi  listen  eingeben, auf clientpi  send "Hallo"'
    }
    Write-Host ''
}
catch {
    Write-Host ''
    Write-Host "  FEHLER: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    exit 1
}
