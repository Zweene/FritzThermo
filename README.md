# FritzThermo 🌡

Eine kleine Menüleisten-App für macOS. Sie zeigt die Temperaturen deiner **FRITZ!DECT-Heizkörperthermostate** (z. B. DECT 301) und **FRITZ!DECT 440** direkt in der Menüleiste an. Die Soll-Temperatur lässt sich dort auch ändern.

> Inoffizielles Projekt, nicht mit AVM verbunden. FRITZ!, FRITZ!Box und FRITZ!DECT sind Marken der AVM GmbH.

## Funktionen

- Ist-Temperatur des gewählten Geräts in der Menüleiste, optional mit Luftfeuchte
- Liste aller Thermostate und Sensoren mit Ist- und Soll-Temperatur, Luftfeuchte (DECT 440), Batteriestand, „Fenster offen“ und „Boost“
- Soll-Temperatur mit **− / +** in 0,5°-Schritten ändern oder auf Komfort-, Absenk-, Aus- und An-Temperatur setzen
- Klick auf ein Gerät zeigt es in der Menüleiste an
- Eigenes Bild als Menüleisten-Symbol möglich
- Automatische Aktualisierung (30 s bis 5 min), Autostart beim Anmelden
- Passwort wird im macOS-Schlüsselbund gespeichert

## Voraussetzungen

- macOS 13 (Ventura) oder neuer
- Xcode Command Line Tools (das volle Xcode ist nicht nötig):
  ```
  xcode-select --install
  ```
- FRITZ!Box mit FRITZ!OS 7 oder neuer

## Installation

### Einfach: DMG herunterladen

1. Unter [**Releases**](https://github.com/Zweene/FritzThermo/releases) die neueste `FritzThermo-x.y.dmg` herunterladen.
2. DMG öffnen und **FritzThermo** auf **Programme** ziehen.
3. FritzThermo aus dem Programme-Ordner starten.

**Hinweis beim ersten Start:** Die App ist nicht von Apple notarisiert. macOS meldet deshalb, dass der Entwickler nicht überprüft werden kann.
- **macOS 15 und neuer:** *Systemeinstellungen → Datenschutz & Sicherheit* öffnen, nach unten scrollen und bei FritzThermo auf **„Dennoch öffnen“** klicken.
- **macOS 13/14:** Rechtsklick auf die App, **Öffnen** wählen und noch einmal **Öffnen** bestätigen.
- Alternativ im Terminal: `xattr -dr com.apple.quarantine /Applications/FritzThermo.app`

### Selbst bauen

```
git clone https://github.com/Zweene/FritzThermo.git
cd FritzThermo
chmod +x build.sh
./build.sh
mv FritzThermo.app /Applications/
open /Applications/FritzThermo.app
```

Ohne git: Auf GitHub **Code → Download ZIP** wählen, entpacken und im Terminal ab `cd FritzThermo` weitermachen.

## Einrichtung

1. Auf das 🌡 in der Menüleiste klicken.
2. Adresse (`fritz.box` oder `192.168.178.1`), Benutzer und Passwort eintragen und speichern.
3. Fragt macOS nach dem Zugriff auf das **lokale Netzwerk**, auf **Erlauben** klicken.
4. Fragt macOS nach dem **Schlüsselbund**, das Mac-Anmeldepasswort eingeben und **Immer erlauben** klicken.

### FRITZ!Box-Benutzer

Der Benutzer braucht unter *System → FRITZ!Box-Benutzer* das Recht **„Smart Home“**. Empfehlung: einen eigenen Benutzer nur mit diesem Recht anlegen.

Bleibt das Feld **Benutzer** leer, verwendet die App den zuletzt angemeldeten FRITZ!Box-Benutzer.

## DMG selbst erstellen

```
chmod +x make-dmg.sh
./make-dmg.sh 1.0
```

Das Skript erzeugt `FritzThermo-1.0.dmg` als Universal-App für Apple Silicon und Intel.

## Update

Laufende App beenden (🌡 → **Beenden**), dann:

```
git pull
./build.sh
rm -rf /Applications/FritzThermo.app
mv FritzThermo.app /Applications/
open /Applications/FritzThermo.app
```

Die Einstellungen bleiben dabei erhalten.

## Technik

- Swift / SwiftUI (`MenuBarExtra`), eine einzige Quelldatei, ohne Abhängigkeiten
- Nutzt das offizielle [AVM AHA-HTTP-Interface](https://avm.de/service/schnittstellen/):
  - Anmeldung über `login_sid.lua` (PBKDF2, bei älterem FRITZ!OS MD5)
  - `getdevicelistinfos` zum Abfragen der Geräte
  - `sethkrtsoll` zum Setzen der Soll-Temperatur
- Die Einstellungen liegen in `UserDefaults`, das Passwort im Schlüsselbund, ein eigenes Symbol unter `~/Library/Application Support/FritzThermo/`

## Lizenz

[MIT](LICENSE)
