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

# Unterscheidet eigene Fehlermeldungen (throw im Skript) von unerwarteten Fehlern.
# Bei unerwarteten Fehlern wird zusaetzlich die Zeile angezeigt, das erleichtert die Suche.
function Test-OwnError {
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    if ($ex -isnot [System.Management.Automation.RuntimeException]) { return $false }
    if ($ex.WasThrownFromThrowStatement) { return $true }
    return ($ex.GetType() -eq [System.Management.Automation.RuntimeException] -and
            $ErrorRecord.CategoryInfo.Category -eq 'OperationStopped')
}

# Liest eine Eingabe und entfernt Leerzeichen am Anfang und Ende.
function Read-Answer {
    param([string]$Prompt)
    return ([string](Read-Host $Prompt)).Trim()
}

function Test-Yes {
    param([string]$Answer)
    return ($Answer -in @('ja', 'j', 'yes', 'y'))
}

function Assert-Environment {
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw "Windows PowerShell 5.1 oder neuer wird benoetigt (gefunden: $($PSVersionTable.PSVersion))."
    }
    if ((Test-Path -Path 'variable:IsWindows') -and -not $IsWindows) {
        throw 'Dieses Skript laeuft nur unter Windows.'
    }
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Bitte PowerShell als Administrator starten (Rechtsklick auf das Startmenue -> Terminal (Administrator)).'
    }
}

function ConvertTo-IPv4Number {
    param([string]$Text)
    $p = $Text.Split('.')
    return ([long]$p[0] * 16777216) + ([long]$p[1] * 65536) + ([long]$p[2] * 256) + [long]$p[3]
}

# Prueft die Werte in $Config, bevor irgendetwas veraendert wird. Die Werte landen in
# YAML-Dateien und Shell-Befehlen auf den Pis - ein Leerzeichen oder Anfuehrungszeichen
# wuerde die Einrichtung dort unbemerkt scheitern lassen.
function Assert-Config {
    $problems = New-Object System.Collections.Generic.List[string]

    $prefix = 0
    if (-not [int]::TryParse([string]$Config.Netmask, [ref]$prefix) -or $prefix -lt 8 -or $prefix -gt 30) {
        $problems.Add("Netmask = '$($Config.Netmask)' muss eine Zahl von 8 bis 30 sein (24 entspricht 255.255.255.0).")
        $prefix = 0
    }

    $octet = '(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
    $ipNumbers = @{}
    foreach ($k in 'BrokerIP', 'ClientIP', 'LaptopIP') {
        $v = [string]$Config[$k]
        if ($v -notmatch "^$octet(\.$octet){3}$") {
            $problems.Add("$k = '$v' ist keine gueltige IPv4-Adresse.")
        }
        else {
            $ipNumbers[$k] = ConvertTo-IPv4Number $v
        }
    }

    if ($ipNumbers.Count -eq 3) {
        if (@($ipNumbers.Values | Sort-Object -Unique).Count -ne 3) {
            $problems.Add('BrokerIP, ClientIP und LaptopIP muessen verschieden sein.')
        }
        if ($prefix -gt 0) {
            $size = [long][Math]::Pow(2, 32 - $prefix)
            $nets = @{}
            foreach ($k in $ipNumbers.Keys) {
                $n = $ipNumbers[$k]
                $nets[$k] = [long][Math]::Floor($n / $size)
                $hostPart = $n % $size
                if ($hostPart -eq 0 -or $hostPart -eq ($size - 1)) {
                    $problems.Add("$k = '$($Config[$k])' ist bei /$prefix keine nutzbare Geraeteadresse.")
                }
            }
            if (@($nets.Values | Sort-Object -Unique).Count -ne 1) {
                $problems.Add("BrokerIP, ClientIP und LaptopIP muessen im selben Netz liegen (/$prefix).")
            }
        }
    }

    foreach ($k in 'BrokerName', 'ClientName') {
        $v = [string]$Config[$k]
        if ($v -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$' -or $v -match '^[0-9]+$') {
            $problems.Add("$k = '$v' ist kein gueltiger Geraetename (Buchstaben, Ziffern, Bindestrich).")
        }
    }
    if ([string]$Config.BrokerName -eq [string]$Config.ClientName) {
        $problems.Add('BrokerName und ClientName muessen verschieden sein.')
    }

    $user = [string]$Config.LinuxUser
    if ($user -cnotmatch '^[a-z_][a-z0-9_-]{0,31}$' -or $user -eq 'root') {
        $problems.Add("LinuxUser = '$user' ist kein gueltiger Benutzername (Kleinbuchstaben, Ziffern, _ und -; nicht root).")
    }

    $yamlWords = @('true', 'false', 'yes', 'no', 'on', 'off', 'null')
    foreach ($k in 'LinuxPass', 'MqttUser', 'MqttPass') {
        $v = [string]$Config[$k]
        if ($v -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            $problems.Add("$k = '$v' darf nur Buchstaben, Ziffern und . _ - enthalten und muss mit Buchstabe oder Ziffer beginnen.")
        }
        elseif ($v -match '^[0-9._-]+$' -or $yamlWords -contains $v) {
            $problems.Add("$k = '$v' wird in der Konfiguration nicht als Text gelesen. Bitte mindestens einen Buchstaben verwenden und Woerter wie true/false/yes/no vermeiden.")
        }
    }

    $topic = [string]$Config.Topic
    if ($topic -notmatch '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$') {
        $problems.Add("Topic = '$topic' darf nur Buchstaben, Ziffern, . _ - und / enthalten (keine Platzhalter + oder #).")
    }

    $tz = [string]$Config.Timezone
    if ($tz -notmatch '^(UTC|[A-Za-z]+(/[A-Za-z0-9_+-]+)+)$') {
        $problems.Add("Timezone = '$tz' ist keine gueltige Zeitzone (Beispiel: Europe/Berlin).")
    }

    if ($problems.Count -gt 0) {
        throw ("Ungueltige Werte im Block `$Config am Anfang des Skripts:`n    - " + ($problems -join "`n    - "))
    }
}

# Haelt den Rechner waehrend Download und Schreiben wach. Ein Laptop im Akkubetrieb
# geht sonst nach einigen Minuten in den Energiesparmodus und das Schreiben bricht ab.
# Klappt das nicht (z. B. eingeschraenkte PowerShell), laeuft das Skript trotzdem weiter.
$KeepAwakeActive = $false

function Set-KeepAwake {
    param([bool]$Enable)
    if (-not $Enable -and -not $script:KeepAwakeActive) { return }
    $script:KeepAwakeActive = $Enable
    try {
        if (-not ('MqttPi.Power' -as [type])) {
            Add-Type -Namespace 'MqttPi' -Name 'Power' -ErrorAction Stop -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
        }
        # ES_CONTINUOUS (0x80000000) und ES_SYSTEM_REQUIRED (0x00000001)
        $flags = if ($Enable) { [uint32]2147483649 } else { [uint32]2147483648 }
        $null = [MqttPi.Power]::SetThreadExecutionState($flags)
    }
    catch { }
}

function Find-RpiImager {
    $candidates = @(
        "$env:ProgramFiles\Raspberry Pi Imager\rpi-imager.exe",
        "${env:ProgramFiles(x86)}\Raspberry Pi Imager\rpi-imager.exe",
        "$env:LOCALAPPDATA\Programs\Raspberry Pi Imager\rpi-imager.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
    }
    $cmd = @(Get-Command rpi-imager.exe -CommandType Application -ErrorAction SilentlyContinue)
    if ($cmd.Count -gt 0) { return $cmd[0].Source }

    # Fallback: Installationsort aus "Apps und Features" (z. B. anderes Laufwerk)
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    try {
        $entries = @(Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
                     Where-Object { $_.DisplayName -like 'Raspberry Pi Imager*' })
        foreach ($e in $entries) {
            $paths = @()
            if ($e.InstallLocation) { $paths += ([string]$e.InstallLocation).Trim('"').TrimEnd('\') + '\rpi-imager.exe' }
            if ($e.DisplayIcon)     { $paths += (([string]$e.DisplayIcon) -replace ',\s*-?\d+$', '').Trim('"') }
            foreach ($p in $paths) {
                if ($p -like '*rpi-imager.exe' -and (Test-Path -LiteralPath $p -PathType Leaf)) { return $p }
            }
        }
    }
    catch { }

    throw 'Raspberry Pi Imager nicht gefunden. Bitte von raspberrypi.com/software installieren.'
}

# Schreibt eine Textdatei ohne BOM und mit Unix-Zeilenenden.
# Beides ist fuer cloud-init zwingend - eine Datei mit BOM wird ignoriert.
# Danach wird die Datei zur Kontrolle zurueckgelesen. SD-Karten und Kartenleser
# setzen gelegentlich kurz aus - dann hilft ein zweiter Versuch.
function Write-UnixFile {
    param(
        [string]$Path,
        [string]$Content
    )
    $normalized = $Content -replace "`r`n", "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $expected = [Convert]::ToBase64String($utf8NoBom.GetBytes($normalized))

    $lastError = 'Inhalt stimmt nach dem Schreiben nicht'
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            [System.IO.File]::WriteAllText($Path, $normalized, $utf8NoBom)
            $actual = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path))
            if ($actual -eq $expected) { return }
            $lastError = 'Inhalt stimmt nach dem Schreiben nicht'
        }
        catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Seconds 1
    }
    throw "Datei $Path konnte nicht korrekt geschrieben werden ($lastError). Karte pruefen oder eine andere Karte verwenden."
}

function Select-TargetDisk {
    Write-Step 'Datentraeger auswaehlen'

    # Nur Wechseldatentraeger. Systemlaufwerke und leere Kartenleser (Groesse 0)
    # werden nie angeboten.
    $disks = @(Get-Disk | Where-Object {
        $_.BusType -in @('USB', 'SD', 'MMC') -and $_.Size -lt 200GB -and
        $_.Size -gt 0 -and -not $_.IsSystem -and -not $_.IsBoot
    } | Sort-Object Number)

    if ($disks.Count -eq 0) {
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
    # Feste Breite: Ohne erkennbare Fensterbreite (z. B. umgeleitete Ausgabe) bliebe die
    # Tabelle sonst leer und die Karte koennte nicht ausgewaehlt werden.
    $table | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    Write-Warn 'ACHTUNG: Der gewaehlte Datentraeger wird vollstaendig geloescht.'
    $choice = Read-Answer 'Nummer eingeben (Abbruch mit Enter)'
    if ([string]::IsNullOrWhiteSpace($choice)) { throw 'Abgebrochen.' }

    $idx = 0
    if (-not [int]::TryParse($choice, [ref]$idx) -or $idx -lt 1 -or $idx -gt $disks.Count) {
        throw "Ungueltige Auswahl: $choice"
    }

    $selected = $disks[$idx - 1]
    if ($selected.IsReadOnly) {
        throw "Datentraeger $($selected.Number) ist schreibgeschuetzt. Schreibschutzschalter am Kartenadapter pruefen (Stellung 'Lock' = geschuetzt). Es wurde nichts veraendert."
    }

    $sizeGb = '{0:N1}' -f ($selected.Size / 1GB)
    Write-Host ''
    Write-Warn "Gewaehlt: Datentraeger $($selected.Number) - $($selected.FriendlyName) - $sizeGb GB"
    $confirm = Read-Answer "Wirklich loeschen und beschreiben? (ja/nein)"
    if (-not (Test-Yes $confirm)) { throw 'Abgebrochen.' }

    return $selected
}

# Zwischen Auswahl und Schreiben koennen durch den Download Minuten vergehen. Vor dem
# Loeschen wird geprueft, dass unter der Nummer noch genau dieselbe Karte steckt.
function Assert-DiskUnchanged {
    param($Selected)

    $now = $null
    try { $now = Get-Disk -Number $Selected.Number -ErrorAction Stop } catch { }

    if (-not $now -or $now.Size -le 0) {
        throw "Die SD-Karte (Datentraeger $($Selected.Number)) ist nicht mehr vorhanden. Es wurde nichts geschrieben. Karte einstecken und das Skript erneut starten."
    }

    $same = ($now.Size -eq $Selected.Size) -and
            ([string]$now.FriendlyName -eq [string]$Selected.FriendlyName) -and
            ([string]$now.UniqueId -eq [string]$Selected.UniqueId) -and
            ([string]$now.SerialNumber -eq [string]$Selected.SerialNumber)

    if (-not $same -or $now.IsSystem -or $now.IsBoot) {
        throw "Unter Datentraeger $($Selected.Number) steckt nicht mehr dieselbe Karte. Zur Sicherheit wurde nichts geschrieben. Bitte das Skript erneut starten."
    }
    if ($now.IsReadOnly) {
        throw "Datentraeger $($Selected.Number) ist schreibgeschuetzt. Schreibschutzschalter am Kartenadapter pruefen (Stellung 'Lock' = geschuetzt). Es wurde nichts veraendert."
    }
}

function Get-TempDir {
    $t = $env:TEMP
    if ([string]::IsNullOrWhiteSpace($t)) { $t = [System.IO.Path]::GetTempPath() }
    return $t
}

# Windows PowerShell 5.1 bietet je nach .NET-Stand kein TLS 1.2 an - dann lehnen
# die Download-Server die Verbindung ab. Steht .NET auf "Systemstandard", bleibt es so.
function Enable-Tls12 {
    try {
        $current = [Net.ServicePointManager]::SecurityProtocol
        if ([int]$current -ne 0 -and -not ($current -band [Net.SecurityProtocolType]::Tls12)) {
            [Net.ServicePointManager]::SecurityProtocol = $current -bor [Net.SecurityProtocolType]::Tls12
        }
    }
    catch { }
}

function Get-HttpStatusCode {
    param($ErrorRecord)
    try {
        $response = $ErrorRecord.Exception.Response
        if ($response -and $response.StatusCode) { return [int]$response.StatusCode }
    }
    catch { }
    return $null
}

# Liefert die Dateigroesse laut Server oder $null, wenn sie nicht zu ermitteln ist.
function Get-RemoteFileSize {
    param([string]$Url)
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 30
        $length = $response.Headers['Content-Length']
        if ($length -is [array]) { $length = $length[0] }
        [long]$n = 0
        if ([long]::TryParse([string]$length, [ref]$n) -and $n -gt 0) { return $n }
    }
    catch { }
    return $null
}

function Assert-FreeSpace {
    param(
        [string]$Directory,
        [long]$Bytes
    )
    $free = $null
    $root = $null
    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Directory))
        $free = (New-Object System.IO.DriveInfo($root)).AvailableFreeSpace
    }
    catch { return }

    $needed = $Bytes + 200MB
    if ($free -lt $needed) {
        throw ("Nicht genug freier Speicher fuer den Download auf {0} ({1:N1} GB noetig, {2:N1} GB frei). Platz schaffen oder das Image auf ein anderes Laufwerk laden und mit -ImagePath uebergeben." -f $root, ($needed / 1GB), ($free / 1GB))
    }
}

# Holt die offizielle SHA-256-Pruefsumme des Images. Raspberry Pi legt neben jedes
# Image eine Datei <name>.sha256, Ubuntu eine SHA256SUMS im selben Ordner.
# Liefert $null, wenn keine Pruefsumme zu bekommen ist (z. B. ohne Internet).
function Get-ExpectedImageHash {
    param([string]$Url)

    $leaf = Split-Path $Url -Leaf
    $dir = $Url.Substring(0, $Url.LastIndexOf('/'))
    foreach ($sumUrl in @("$Url.sha256", "$dir/SHA256SUMS")) {
        $tmp = $null
        try {
            $tmp = [System.IO.Path]::GetTempFileName()
            Invoke-WebRequest -Uri $sumUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 30
            foreach ($line in [System.IO.File]::ReadAllLines($tmp)) {
                if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(\S.*?)\s*$') {
                    $hash = $Matches[1]
                    $name = ($Matches[2] -split '[\\/]')[-1]
                    if ($name -eq $leaf) { return $hash.ToUpperInvariant() }
                }
            }
        }
        catch { }
        finally {
            if ($tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }
    return $null
}

# Erkennt das Dateiformat an den ersten Bytes.
function Get-ImageFormat {
    param(
        [byte[]]$Head,
        [int]$Count
    )
    if ($Count -lt 8) { return $null }
    $hex = (($Head[0..7] | ForEach-Object { $_.ToString('X2') }) -join '')
    if ($hex.StartsWith('FD377A585A00')) { return 'xz' }
    if ($hex.StartsWith('1F8B'))         { return 'gz' }
    if ($hex.StartsWith('504B0304'))     { return 'zip' }
    if ($hex.StartsWith('28B52FFD'))     { return 'zst' }
    if ($hex.StartsWith('425A68'))       { return 'bz2' }
    if ($hex.StartsWith('377ABCAF271C')) { return '7z' }
    if ($Count -ge 512 -and $Head[510] -eq 0x55 -and $Head[511] -eq 0xAA) { return 'img' }
    return $null
}

function Get-FormatFromName {
    param([string]$Name)
    if ($Name -match '\.xz$') { return 'xz' }
    if ($Name -match '\.gz$') { return 'gz' }
    return $null
}

function Read-Bytes {
    param(
        [System.IO.Stream]$Stream,
        [int]$Count
    )
    $buffer = New-Object byte[] $Count
    $total = 0
    while ($total -lt $Count) {
        $n = $Stream.Read($buffer, $total, $Count - $total)
        if ($n -le 0) { break }
        $total += $n
    }
    return , @($buffer, $total)
}

# Prueft eine Image-Datei grob, ohne sie zu entpacken: Dateityp anhand der ersten Bytes,
# bei .xz zusaetzlich das Dateiende - ein abgebrochener Download hat kein gueltiges Ende.
# Rueckgabe: $null, wenn alles passt, sonst eine kurze Beschreibung des Problems.
function Get-ImageProblem {
    param(
        [string]$Path,
        [string]$ExpectedFormat
    )
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    }
    catch {
        return "Datei kann nicht gelesen werden: $($_.Exception.Message)"
    }
    try {
        $length = $fs.Length
        if ($length -lt 1MB) { return 'Datei ist zu klein fuer ein Image' }

        $r = Read-Bytes -Stream $fs -Count 512
        $format = Get-ImageFormat -Head $r[0] -Count $r[1]
        if (-not $format) { return 'unbekanntes Dateiformat (erwartet .img.xz oder .img.gz)' }
        if ($ExpectedFormat -and $format -ne $ExpectedFormat) { return "Dateiformat $format statt $ExpectedFormat" }

        if ($format -eq 'xz') {
            $tailLength = [int][Math]::Min(4096, $length)
            $null = $fs.Seek(-$tailLength, [System.IO.SeekOrigin]::End)
            $t = Read-Bytes -Stream $fs -Count $tailLength
            $tail = $t[0]
            $i = $t[1] - 1
            while ($i -ge 0 -and $tail[$i] -eq 0) { $i-- }
            if ($i -lt 1 -or $tail[$i - 1] -ne 0x59 -or $tail[$i] -ne 0x5A) {
                return 'Datei ist unvollstaendig (abgebrochener Download?)'
            }
        }
        return $null
    }
    catch {
        return "Datei kann nicht gelesen werden: $($_.Exception.Message)"
    }
    finally {
        $fs.Dispose()
    }
}

# Vergleicht die Pruefsumme mit der offiziellen. Rueckgabe wie Get-ImageProblem.
function Test-ImageHash {
    param(
        [string]$Path,
        [string]$ExpectedHash
    )
    if (-not $ExpectedHash) {
        Write-Warn 'Offizielle Pruefsumme nicht abrufbar, Pruefung uebersprungen.'
        return $null
    }
    Write-Host '    Pruefsumme wird kontrolliert ...'
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -ne $ExpectedHash) { return 'Pruefsumme stimmt nicht' }
    Write-Ok 'Pruefsumme stimmt.'
    return $null
}

function Get-ImageFile {
    param([string]$SelectedRole)

    if ($ImagePath) {
        if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) { throw "Datei nicht gefunden: $ImagePath" }
        $fullPath = (Resolve-Path -LiteralPath $ImagePath).ProviderPath
        $problem = Get-ImageProblem -Path $fullPath
        if ($problem) { throw "Image-Datei unbrauchbar: $problem ($fullPath)" }
        Write-Ok "Verwende vorhandenes Image: $ImagePath"
        return $fullPath
    }

    # Fortschrittsanzeige aus: Mit Anzeige ist Invoke-WebRequest in
    # Windows PowerShell 5.1 bei grossen Dateien um ein Vielfaches langsamer.
    $ProgressPreference = 'SilentlyContinue'
    Enable-Tls12

    $url = $ImageUrls[$SelectedRole]
    $cacheDir = Join-Path (Get-TempDir) 'mqtt-pi-images'
    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    $target = Join-Path $cacheDir (Split-Path $url -Leaf)
    $part = "$target.part"
    $expectedFormat = Get-FormatFromName $target
    $expectedHash = $null
    $hashFetched = $false

    if (Test-Path -LiteralPath $target -PathType Leaf) {
        Write-Ok "Image bereits vorhanden: $target"
        $problem = Get-ImageProblem -Path $target -ExpectedFormat $expectedFormat
        if (-not $problem) {
            $expectedHash = Get-ExpectedImageHash -Url $url
            $hashFetched = $true
            $problem = Test-ImageHash -Path $target -ExpectedHash $expectedHash
        }
        if (-not $problem) { return $target }

        Write-Warn "Gespeichertes Image ist unbrauchbar ($problem) und wird neu geladen."
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    }

    Write-Step 'Image herunterladen'
    Write-Host "    Quelle: $url"
    Write-Host '    Das kann je nach Verbindung einige Minuten dauern.'

    if (-not $hashFetched) { $expectedHash = Get-ExpectedImageHash -Url $url }
    $expectedLength = Get-RemoteFileSize -Url $url
    if ($expectedLength) { Assert-FreeSpace -Directory $cacheDir -Bytes $expectedLength }

    # Geladen wird in eine .part-Datei. Erst wenn sie vollstaendig und geprueft ist,
    # bekommt sie den endgueltigen Namen. Ein abgebrochener Download (Strg+C, Netz weg,
    # Absturz) kann so nie als fertiges Image im Zwischenspeicher landen.
    $maxAttempts = 3
    $lastError = $null
    $done = $false
    try {
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            try {
                Invoke-WebRequest -Uri $url -OutFile $part -UseBasicParsing

                if (-not (Test-Path -LiteralPath $part -PathType Leaf)) {
                    throw 'Es wurde keine Datei gespeichert.'
                }
                $size = (Get-Item -LiteralPath $part).Length
                if ($expectedLength -and $size -ne $expectedLength) {
                    throw "Download unvollstaendig ($size von $expectedLength Bytes)."
                }
                $problem = Get-ImageProblem -Path $part -ExpectedFormat $expectedFormat
                if ($problem) { throw "Heruntergeladene Datei unbrauchbar: $problem." }
                $problem = Test-ImageHash -Path $part -ExpectedHash $expectedHash
                if ($problem) { throw "Heruntergeladene Datei beschaedigt: $problem." }

                Move-Item -LiteralPath $part -Destination $target -Force
                $done = $true
                break
            }
            catch {
                $lastError = $_.Exception.Message
                $status = Get-HttpStatusCode $_
                # 4xx (ausser Zeitueberschreitung/zu viele Anfragen) wird durch Wiederholen nicht besser
                if ($status -ge 400 -and $status -lt 500 -and $status -ne 408 -and $status -ne 429) { break }
                if ($attempt -lt $maxAttempts) {
                    $wait = 5 * $attempt * $attempt
                    Write-Warn "Versuch $attempt von $maxAttempts fehlgeschlagen: $lastError"
                    Write-Warn "Neuer Versuch in $wait Sekunden ..."
                    Start-Sleep -Seconds $wait
                }
            }
        }
    }
    finally {
        if (-not $done) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
    }

    if (-not $done) {
        throw @"
Download fehlgeschlagen: $lastError

Die Adresse im Skript ist moeglicherweise veraltet. Bitte das Image von Hand laden:
  broker -> raspberrypi.com/software/operating-systems (Raspberry Pi OS Lite, 64-bit)
  client -> ubuntu.com/download/raspberry-pi (Ubuntu Server 24.04 LTS, 64-bit)
und danach mit -ImagePath uebergeben.
"@
    }

    Write-Ok "Gespeichert: $target"
    return $target
}

# Mindestdauer eines echten Schreibvorgangs. Ein Image mit mehreren GB kann nicht in
# wenigen Sekunden geschrieben und geprueft sein - endet der Imager so schnell, hat er
# nicht geschrieben (z. B. weil bereits ein Imager-Fenster offen war).
$MinFlashSeconds = 10

function Invoke-Flash {
    param(
        [string]$Imager,
        [string]$Image,
        [int]$DiskNumber
    )

    Write-Step 'Image auf die Karte schreiben'

    if (@(Get-Process -Name 'rpi-imager' -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'Der Raspberry Pi Imager ist bereits geoeffnet. Bitte das Imager-Fenster schliessen und das Skript erneut starten. Es wurde nichts geschrieben.'
    }

    Write-Host '    Dies dauert je nach Karte 3 bis 15 Minuten. Bitte nicht abziehen.'

    $device = "\\.\PHYSICALDRIVE$DiskNumber"
    $started = Get-Date
    $finished = $false
    $startFailed = $false
    $proc = $null
    try {
        try {
            $proc = Start-Process -FilePath $Imager `
                                  -ArgumentList @('--cli', "`"$Image`"", "`"$device`"") `
                                  -Wait -PassThru -NoNewWindow
        }
        catch {
            $startFailed = $true
            throw "Raspberry Pi Imager konnte nicht gestartet werden: $($_.Exception.Message)"
        }
        $finished = $true
    }
    finally {
        if (-not $finished -and -not $startFailed) {
            # Abbruch mit Strg+C: Der Imager wuerde sonst im Hintergrund weiterschreiben.
            try {
                Get-Process -Name 'rpi-imager' -ErrorAction SilentlyContinue |
                    Where-Object { $_.StartTime -ge $started.AddSeconds(-5) } |
                    Stop-Process -Force -ErrorAction SilentlyContinue
            }
            catch { }
            Write-Warn 'Schreiben abgebrochen. Die Karte ist unvollstaendig und muss neu beschrieben werden.'
        }
    }

    $exitCode = if ($proc) { $proc.ExitCode } else { $null }
    if ($null -eq $exitCode) { $exitCode = 'unbekannt' }
    if ($exitCode -ne 0) {
        throw "Schreiben fehlgeschlagen (Exit-Code $exitCode). Karte pruefen oder andere Karte verwenden."
    }
    $seconds = [int]((Get-Date) - $started).TotalSeconds
    if ($seconds -lt $MinFlashSeconds) {
        throw "Schreiben fehlgeschlagen (Exit-Code 0, Imager nach $seconds Sekunden beendet - das ist zu schnell). Imager-Fenster schliessen, Karte pruefen und erneut versuchen."
    }
    Write-Ok 'Image geschrieben und geprueft.'
}

function Test-DriveLetter {
    param($Letter)
    return ([string]$Letter -match '^[A-Za-z]$')
}

# Gleiche Hardware wie bei der Auswahl? Wird nur gebraucht, falls Windows die Karte
# nach dem Schreiben unter einer neuen Datentraegernummer meldet.
function Test-SameDiskHardware {
    param($A, $B)
    return ($A.Size -eq $B.Size) -and
           ([string]$A.FriendlyName -eq [string]$B.FriendlyName) -and
           ([string]$A.SerialNumber -eq [string]$B.SerialNumber)
}

# Sucht Partitionen, deren Volume das gesuchte Label traegt.
# Mit -Disk nur auf der beschriebenen Karte, sonst auf allen Nicht-System-Datentraegern.
function Find-BootPartitions {
    param(
        [string]$Label,
        $Disk
    )

    $found = @()
    foreach ($p in @(Get-Partition -ErrorAction SilentlyContinue)) {
        try {
            $hasLetter = Test-DriveLetter $p.DriveLetter
            # Partition ohne Laufwerksbuchstaben: nur passende Groesse betrachten
            if (-not $hasLetter -and ($p.Size -ge 2GB -or $p.Size -le 100MB)) { continue }
            $v = Get-Volume -Partition $p -ErrorAction SilentlyContinue
            if (-not $v -or $v.FileSystemLabel -ne $Label) { continue }
            $letter = $null
            if ($hasLetter) { $letter = [string]$p.DriveLetter }
            $found += [PSCustomObject]@{
                Partition   = $p
                DiskNumber  = $p.DiskNumber
                DriveLetter = $letter
            }
        }
        catch { }
    }

    if ($Disk) {
        $onDisk = @($found | Where-Object { $_.DiskNumber -eq $Disk.Number })
        if ($onDisk.Count -gt 0) { return $onDisk }
        return @($found | Where-Object {
            $d = Get-Disk -Number $_.DiskNumber -ErrorAction SilentlyContinue
            $d -and -not $d.IsSystem -and -not $d.IsBoot -and (Test-SameDiskHardware $d $Disk)
        })
    }

    return @($found | Where-Object {
        $d = Get-Disk -Number $_.DiskNumber -ErrorAction SilentlyContinue
        -not ($d -and ($d.IsSystem -or $d.IsBoot))
    })
}

function Get-FreeDriveLetter {
    $used = @()
    try { $used += @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name }) } catch { }
    try { $used += @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1) }) } catch { }
    try { $used += @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object { [string]$_.DriveLetter }) } catch { }
    return [char[]](68..90) | Where-Object { $used -notcontains [string]$_ } | Select-Object -First 1
}

function Wait-BootPartition {
    param(
        [string]$Label,
        [int]$TimeoutSeconds = 120,
        $Disk
    )

    Write-Step "Boot-Partition '$Label' suchen"

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $round = 0
    while ((Get-Date) -lt $deadline) {
        $round++

        # Gelegentlich bemerkt Windows die neue Partitionstabelle erst nach einem Rescan
        if ($round % 5 -eq 0) {
            try { Update-HostStorageCache -ErrorAction Stop } catch { }
        }
        if ($Disk) {
            try {
                $d = Get-Disk -Number $Disk.Number -ErrorAction Stop
                if ($d.IsOffline) { Set-Disk -Number $Disk.Number -IsOffline $false -ErrorAction Stop }
            }
            catch { }
        }

        $parts = @()
        try { $parts = @(Find-BootPartitions -Label $Label -Disk $Disk) } catch { }

        if ($parts.Count -gt 1) {
            $where = ($parts | ForEach-Object {
                if ($_.DriveLetter) { "$($_.DriveLetter):" } else { "Datentraeger $($_.DiskNumber)" }
            }) -join ', '
            throw "Mehrere Boot-Partitionen '$Label' gefunden ($where). Bitte nur die Karte eingesteckt lassen, die eingerichtet werden soll, und das Skript mit -SkipFlash erneut starten."
        }

        if ($parts.Count -eq 1) {
            $hit = $parts[0]

            if ($hit.DriveLetter) {
                $path = "$($hit.DriveLetter):"
                if ([System.IO.Directory]::Exists("$path\")) {
                    Write-Ok "Gefunden unter $path"
                    return $path
                }
            }
            else {
                # Partition ohne Laufwerksbuchstaben: einen zuweisen
                $p = $hit.Partition
                try {
                    Add-PartitionAccessPath -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber -AssignDriveLetter -ErrorAction Stop
                }
                catch {
                    try {
                        $free = Get-FreeDriveLetter
                        if ($free) { Set-Partition -InputObject $p -NewDriveLetter $free -ErrorAction Stop }
                    }
                    catch { }
                }
                try {
                    $p2 = Get-Partition -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber -ErrorAction Stop
                    if (Test-DriveLetter $p2.DriveLetter) {
                        $path = "$($p2.DriveLetter):"
                        if ([System.IO.Directory]::Exists("$path\")) {
                            Write-Ok "Laufwerksbuchstabe $($p2.DriveLetter): zugewiesen"
                            return $path
                        }
                    }
                }
                catch { }
            }
        }

        Start-Sleep -Seconds 3
    }

    throw "Boot-Partition '$Label' nicht gefunden. Karte kurz abziehen, wieder einstecken und das Skript mit -SkipFlash erneut starten."
}

# Leert den Schreibpuffer und wirft die Karte aus. Liefert $true, wenn die Karte
# danach wirklich nicht mehr erreichbar ist.
function Invoke-EjectCard {
    param([string]$Drive)

    # Puffer leeren: Die Dateien sind damit sicher auf der Karte, auch wenn das
    # Auswerfen danach nicht klappt.
    try { Write-VolumeCache -DriveLetter $Drive.Substring(0, 1) -ErrorAction Stop } catch { }

    try {
        $shell = New-Object -ComObject Shell.Application
        $item = $shell.Namespace(17).ParseName($Drive)
        if (-not $item) { return $false }
        $item.InvokeVerb('Eject')
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            if (-not [System.IO.Directory]::Exists("$Drive\")) { return $true }
        }
    }
    catch { }
    return $false
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

function Select-LaptopAdapter {
    param([object[]]$Adapters)

    if ($Adapters.Count -eq 1) {
        $adapter = $Adapters[0]
        Write-Ok "Adapter: $($adapter.Name) - $($adapter.InterfaceDescription)"
        return $adapter
    }

    $i = 0
    $table = foreach ($a in $Adapters) {
        $i++
        [PSCustomObject]@{
            Nr          = $i
            Name        = $a.Name
            Beschreibung = $a.InterfaceDescription
            Tempo       = $a.LinkSpeed
        }
    }
    $table | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Write-Host '    Gemeint ist der Anschluss, an dem das Netzwerkkabel zum Switch haengt.'
    $sel = Read-Answer '    Nummer eingeben'
    $idx = 0
    if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $Adapters.Count) {
        throw "Ungueltige Auswahl: $sel"
    }
    return $Adapters[$idx - 1]
}

# Alle Vorkommen der Laptop-Adresse, auch auf getrennten Adaptern (dann steht sie
# nur im dauerhaften Speicher). Optional auf einen Adapter eingeschraenkt.
function Get-LaptopAddressEntries {
    param([int]$InterfaceIndex = -1)
    $found = @()
    foreach ($store in 'ActiveStore', 'PersistentStore') {
        try {
            $found += @(Get-NetIPAddress -IPAddress $Config.LaptopIP -AddressFamily IPv4 `
                                         -PolicyStore $store -ErrorAction SilentlyContinue)
        }
        catch { }
    }
    if ($InterfaceIndex -ge 0) {
        $found = @($found | Where-Object { $_.InterfaceIndex -eq $InterfaceIndex })
    }
    return $found
}

function Get-AdapterLabel {
    param($Entry)
    if ($Entry.InterfaceAlias) { return [string]$Entry.InterfaceAlias }
    return "Index $($Entry.InterfaceIndex)"
}

# Entfernt die Laptop-Adresse von einem Adapter - aus dem aktiven und dem dauerhaften
# Speicher - und prueft, dass sie wirklich weg ist.
function Remove-LaptopAddressFrom {
    param([int]$InterfaceIndex)
    try {
        Remove-NetIPAddress -InterfaceIndex $InterfaceIndex -IPAddress $Config.LaptopIP `
                            -Confirm:$false -ErrorAction SilentlyContinue
    }
    catch { }
    try {
        Remove-NetIPAddress -InterfaceIndex $InterfaceIndex -IPAddress $Config.LaptopIP `
                            -PolicyStore PersistentStore -Confirm:$false -ErrorAction SilentlyContinue
    }
    catch { }
    if (@(Get-LaptopAddressEntries -InterfaceIndex $InterfaceIndex).Count -gt 0) {
        throw "Adresse $($Config.LaptopIP) konnte nicht entfernt werden. Von Hand entfernen: Remove-NetIPAddress -InterfaceIndex $InterfaceIndex -IPAddress $($Config.LaptopIP)"
    }
}

function Enable-AdapterDhcp {
    param([int]$InterfaceIndex)
    # Ein inzwischen abgesteckter USB-Adapter hat keine Schnittstelle mehr - dann gibt
    # es auch nichts einzuschalten.
    $iface = Get-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if (-not $iface) { return }
    if ($iface.Dhcp -ne 'Enabled') {
        try {
            Set-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop
        }
        catch {
            throw "DHCP konnte nicht wieder eingeschaltet werden: $($_.Exception.Message)"
        }
        Write-Ok 'DHCP wieder eingeschaltet.'
    }
}

# Fuegt dem Netzwerkadapter eine zweite, feste Adresse hinzu, ohne DHCP abzuschalten.
# Dasselbe Prinzip wie bei den Pis: am Router zaehlt die DHCP-Adresse, am Switch
# die feste. Kein Umschalten mehr noetig.
function Set-LaptopAddress {
    param([switch]$Remove)

    Write-Step 'Netzwerkadapter des Laptops'

    $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop |
                  Where-Object { $_.Status -eq 'Up' } |
                  Sort-Object -Property @{ Expression = { $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN' } }, Name)

    if ($Remove) {
        # Beim Entfernen ist das Kabel oft schon abgezogen. Dann wird die Adresse
        # direkt gesucht, statt mit "kein aktiver Adapter" abzubrechen.
        $removedAny = $false
        if ($adapters.Count -gt 0) {
            $adapter = Select-LaptopAdapter -Adapters $adapters
            if (@(Get-LaptopAddressEntries -InterfaceIndex $adapter.ifIndex).Count -gt 0) {
                Remove-LaptopAddressFrom -InterfaceIndex $adapter.ifIndex
                Write-Ok "Adresse $($Config.LaptopIP) entfernt."
                Enable-AdapterDhcp -InterfaceIndex $adapter.ifIndex
                $removedAny = $true
            }
        }

        # Reste auf anderen Adaptern ebenfalls entfernen
        $others = @(Get-LaptopAddressEntries | Sort-Object -Property InterfaceIndex -Unique)
        foreach ($e in $others) {
            Remove-LaptopAddressFrom -InterfaceIndex $e.InterfaceIndex
            Write-Ok "Adresse $($Config.LaptopIP) entfernt (Adapter '$(Get-AdapterLabel $e)')."
            Enable-AdapterDhcp -InterfaceIndex $e.InterfaceIndex
            $removedAny = $true
        }

        if (-not $removedAny) {
            Write-Warn "Adresse $($Config.LaptopIP) war nicht gesetzt."
        }
        return
    }

    if ($adapters.Count -eq 0) {
        throw 'Kein aktiver Netzwerkadapter gefunden. Netzwerkkabel eingesteckt?'
    }

    $adapter = Select-LaptopAdapter -Adapters $adapters

    # Ist die Adresse noch auf einem anderen Adapter gesetzt (z. B. weil frueher ein
    # anderer Anschluss gewaehlt wurde), waere sie doppelt vergeben. Dort entfernen.
    $elsewhere = @(Get-LaptopAddressEntries |
                   Where-Object { $_.InterfaceIndex -ne $adapter.ifIndex } |
                   Sort-Object -Property InterfaceIndex -Unique)
    foreach ($e in $elsewhere) {
        Write-Warn "Adresse $($Config.LaptopIP) war auf Adapter '$(Get-AdapterLabel $e)' gesetzt und wird dort entfernt."
        # Ein Rest auf einem anderen Adapter stoert hier nicht zwingend - darum nur warnen
        try { Remove-LaptopAddressFrom -InterfaceIndex $e.InterfaceIndex }
        catch { Write-Warn $_.Exception.Message }
    }

    $existing = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex `
                                 -IPAddress $Config.LaptopIP `
                                 -ErrorAction SilentlyContinue

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
        $existing = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex `
                                     -IPAddress $Config.LaptopIP `
                                     -ErrorAction SilentlyContinue
    }

    $netshExit = 1
    try {
        $null = & netsh interface ipv4 set interface interface="$($adapter.ifIndex)" dhcpstaticipcoexistence=enabled
        $netshExit = $LASTEXITCODE
    }
    catch { $netshExit = 1 }
    if ($netshExit -ne 0) {
        throw 'Dieses Windows erlaubt DHCP und feste Adresse nicht gleichzeitig. Bitte die Adresse von Hand setzen (siehe Technische Doku).'
    }
    Write-Ok 'DHCP und feste Adresse duerfen gleichzeitig bestehen.'

    if ($existing) {
        Write-Ok "Adresse $($Config.LaptopIP) ist bereits gesetzt."
    }
    else {
        # Ein Rest nur im dauerhaften Speicher liesse New-NetIPAddress mit
        # "existiert bereits" abbrechen
        if (@(Get-LaptopAddressEntries -InterfaceIndex $adapter.ifIndex).Count -gt 0) {
            Remove-LaptopAddressFrom -InterfaceIndex $adapter.ifIndex
        }
        try {
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex `
                             -IPAddress $Config.LaptopIP `
                             -PrefixLength ([int]$Config.Netmask) `
                             -ErrorAction Stop | Out-Null
        }
        catch {
            throw "Adresse $($Config.LaptopIP) konnte nicht hinzugefuegt werden: $($_.Exception.Message)"
        }
        Write-Ok "Adresse $($Config.LaptopIP)/$($Config.Netmask) hinzugefuegt."
    }

    # Kontrolle: Adresse muss jetzt wirklich vorhanden sein
    $check = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex `
                                -IPAddress $Config.LaptopIP `
                                -ErrorAction SilentlyContinue)
    if ($check.Count -eq 0) {
        throw "Adresse $($Config.LaptopIP) ist nach dem Setzen nicht vorhanden. Bitte die Adresse von Hand setzen (siehe Technische Doku)."
    }
    if ([string]$check[0].AddressState -eq 'Duplicate') {
        Write-Warn "Adresse $($Config.LaptopIP) wird im Netz bereits von einem anderen Geraet verwendet."
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
        Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}

# ============================================================================
#  HAUPTPROGRAMM
# ============================================================================

try {
    Write-Host ''
    Write-Host '  MQTT-Umgebung - SD-Karte erstellen' -ForegroundColor White
    Write-Host '  LF07 / LS02 - Mosquitto auf Raspberry Pi' -ForegroundColor DarkGray
    Write-Host '  ----------------------------------------' -ForegroundColor DarkGray

    Assert-Environment
    Assert-Admin
    Assert-Config

    # --- Rolle waehlen ---
    if (-not $Role) {
        Write-Host ''
        Write-Host '  Was soll eingerichtet werden?'
        Write-Host ''
        Write-Host '  [1] Broker  - neue SD-Karte fuer brokerpi erstellen'
        Write-Host '  [2] Client  - neue SD-Karte fuer clientpi erstellen'
        Write-Host '  [3] Laptop  - diesem Laptop eine Zusatzadresse fuer den Switch geben (keine SD-Karte)'
        Write-Host ''
        $sel = Read-Answer '  Auswahl (1, 2 oder 3)'
        switch ($sel) {
            '1' { $Role = 'broker' }
            '2' { $Role = 'client' }
            '3' { $Role = 'laptop' }
            default { throw "Ungueltige Auswahl: $sel" }
        }
    }

    # --- Parameter pruefen, bevor irgendetwas veraendert wird ---
    if ($RemoveLaptopAddress -and $Role -ne 'laptop') {
        throw '-RemoveLaptopAddress geht nur zusammen mit -Role laptop. Es wurde nichts veraendert.'
    }
    if ($Role -eq 'laptop' -and ($SkipFlash -or $ImagePath)) {
        Write-Warn '-SkipFlash und -ImagePath gelten nur fuer SD-Karten und werden ignoriert.'
    }
    elseif ($SkipFlash -and $ImagePath) {
        Write-Warn '-ImagePath wird ignoriert, weil mit -SkipFlash kein Image geschrieben wird.'
    }
    elseif ($ImagePath) {
        # Vor der Kartenauswahl pruefen, damit nicht erst nach der Rueckfrage abgebrochen wird
        if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) { throw "Datei nicht gefunden: $ImagePath" }
        $problem = Get-ImageProblem -Path (Resolve-Path -LiteralPath $ImagePath).ProviderPath
        if ($problem) { throw "Image-Datei unbrauchbar: $problem ($ImagePath)" }
    }

    # --- Vorher genau anzeigen, was veraendert wird ---
    Write-Step 'Das wird veraendert'
    $plan = switch ($Role) {
        'broker' {
            if ($SkipFlash) { 'Auf der eingesteckten Karte werden nur die Einstellungsdateien ersetzt. Nichts wird geloescht.' }
            else { 'Die SD-Karte, die du gleich auswaehlst, wird komplett geloescht.' }
            "Darauf kommt Raspberry Pi OS mit dem MQTT-Broker (Name $($Config.BrokerName), Adresse $($Config.BrokerIP))."
            'Am Laptop wird nichts veraendert.'
        }
        'client' {
            if ($SkipFlash) { 'Auf der eingesteckten Karte werden nur die Einstellungsdateien ersetzt. Nichts wird geloescht.' }
            else { 'Die SD-Karte, die du gleich auswaehlst, wird komplett geloescht.' }
            "Darauf kommt Ubuntu Server mit dem MQTT-Client (Name $($Config.ClientName), Adresse $($Config.ClientIP))."
            'Am Laptop wird nichts veraendert.'
        }
        'laptop' {
            if ($RemoveLaptopAddress) {
                "Die Zusatzadresse $($Config.LaptopIP) wird vom Netzwerkanschluss entfernt."
                'Sonst wird nichts veraendert.'
            }
            else {
                "Der Netzwerkanschluss zum Switch bekommt zusaetzlich die Adresse $($Config.LaptopIP)."
                'Die bisherige automatische Adresse bleibt, Internet funktioniert weiter wie bisher.'
                'Es wird nichts geloescht und keine SD-Karte beschrieben.'
                'Rueckgaengig: Skript mit -Role laptop -RemoveLaptopAddress starten.'
            }
        }
    }
    $plan | ForEach-Object { Write-Host "    - $_" }
    Write-Host ''

    # --- Laptop: nur Netzwerk, keine SD-Karte ---
    if ($Role -eq 'laptop') {
        $confirm = Read-Answer '  Fortfahren? (ja/nein)'
        if (-not (Test-Yes $confirm)) { throw 'Abgebrochen. Es wurde nichts veraendert.' }

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
    $disk = $null
    if (-not $SkipFlash) {
        $imager = Find-RpiImager
        Write-Ok "Imager:   $imager"

        $disk  = Select-TargetDisk

        Set-KeepAwake $true
        $image = Get-ImageFile -SelectedRole $Role

        Assert-DiskUnchanged -Selected $disk
        Invoke-Flash -Imager $imager -Image $image -DiskNumber $disk.Number
        Set-KeepAwake $false
    }
    else {
        Write-Warn 'Schreiben uebersprungen (-SkipFlash).'
    }

    # --- Konfiguration ablegen ---
    $bootDrive = Wait-BootPartition -Label $label -Disk $disk

    Write-Step 'Konfigurationsdateien schreiben'

    $userData = if ($Role -eq 'broker') { Get-BrokerUserData } else { Get-ClientUserData }
    $netConf  = Get-NetworkConfig -SelectedRole $Role

    # Pfade bewusst als Text: Ein Laufwerk, das erst waehrend des Skripts erscheint,
    # kennt PowerShell selbst (Join-Path, Test-Path) unter Umstaenden noch nicht.
    Write-UnixFile -Path "$bootDrive\user-data"      -Content $userData
    Write-Ok 'user-data geschrieben'

    Write-UnixFile -Path "$bootDrive\network-config" -Content $netConf
    Write-Ok 'network-config geschrieben'

    # meta-data muss vorhanden sein, darf aber leer bleiben
    $metaPath = "$bootDrive\meta-data"
    if (-not [System.IO.File]::Exists($metaPath)) {
        Write-UnixFile -Path $metaPath -Content "instance-id: $hostName`n"
        Write-Ok 'meta-data angelegt'
    }

    # Raspberry Pi OS: leere Datei "ssh" aktiviert SSH auch ohne cloud-init
    if ($Role -eq 'broker') {
        Write-UnixFile -Path "$bootDrive\ssh" -Content ''
        Write-Ok 'SSH freigeschaltet'
    }

    # --- Karte auswerfen ---
    Write-Step 'Karte auswerfen'
    if (Invoke-EjectCard -Drive $bootDrive) {
        Write-Ok 'Ausgeworfen. Karte kann entnommen werden.'
    }
    else {
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
    if (-not (Test-OwnError $_)) {
        $line = $_.InvocationInfo.ScriptLineNumber
        $code = ([string]$_.InvocationInfo.Line).Trim()
        Write-Host "  (unerwarteter Fehler in Zeile ${line}: $code)" -ForegroundColor DarkGray
    }
    Write-Host ''
    exit 1
}
finally {
    Set-KeepAwake $false
}