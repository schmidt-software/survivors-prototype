# Survivors Prototype

Ein actionreiches Survivors-like (Vampire-Survivors-Stil), gebaut mit **Godot 4** für PC und Mobile. Läuft direkt im Browser.

**Live spielen:** https://schmidt-software.github.io/survivors-prototype/

## Spielprinzip

- Dein Charakter schießt automatisch auf den nächsten Gegner.
- Gegner spawnen in Wellen von außerhalb des Bildschirms, werden mit der Zeit zahlreicher, schneller und zäher. Ab und zu erscheint ein stärkerer Gegnertyp (lila).
- Besiegte Gegner lassen XP-Kristalle fallen. Genug XP bringt ein Level-Up, bei dem du eines von 3 zufälligen Upgrades wählst:
  Schaden, Feuerrate, Zusatzprojektil, Tempo, Magnet (Aufsammelradius), Lebenskraft.
- Bei 0 HP ist das Spiel vorbei.

## Steuerung

| Aktion | PC | Mobile / Touch |
|---|---|---|
| Bewegen | WASD, Pfeiltasten, Gamepad | Finger ziehen (virtueller Joystick an der Aufsetzstelle) |
| Upgrade wählen | Taste `1`–`3` oder Klick | Karte antippen |
| Start / Fortfahren | Enter, Leertaste oder Klick | Tippen |

Mausklicks werden als Touch behandelt (`emulate_touch_from_mouse`).

**Controller:** A / Cross startet das Spiel und bestätigt nach Game Over. Bei
einem Level-Up wählst du mit D-Pad links/rechts oder dem linken Stick eine
gelb markierte Karte und bestätigst mit A / Cross. Den Stick zwischen zwei
Schritten loslassen. Bei der Namenseingabe speichert A / Cross den Namen
(ohne Eingabe als „Anonym“); für eigenen Text wird eine Tastatur benötigt.

## Startseite und Bestenliste

- Das Spiel startet auf einer Startseite mit den **Top 10 Highscores** (Rang, Name, Score) und dem Score des letzten Laufs.
- **Score** = Kills × 10 + überlebte Sekunden.
- Reicht ein Score für die Top 10, erscheint nach dem Game Over ein Eingabefeld für den Namen (max. 12 Zeichen, leer ergibt „Anonym").
- **Speicherort:** lokal in `user://highscores.json`. Im Browser liegt das im IndexedDB des jeweiligen Browsers, auf dem Desktop im Godot-User-Verzeichnis. Die Liste ist also pro Gerät und Browser getrennt und geht verloren, wenn Website-Daten gelöscht werden. Eine gemeinsame Online-Bestenliste bräuchte ein Backend.

## Projektstruktur

```
survivors/
├── project.godot        # Projekteinstellungen (Renderer: gl_compatibility, Viewport 1280x720)
├── main.tscn            # Einzige Szene (Node2D + Skript)
├── main.gd              # Gesamte Spiellogik, Zeichnen und UI
├── export_presets.cfg   # Web-Export-Preset (Ausgabe nach docs/)
└── docs/                # Fertiger Web-Export, wird von GitHub Pages ausgeliefert
```

Der Prototyp benötigt keine externen Assets: Alles wird per `_draw()` gezeichnet. Spielzustände in `main.gd`: `menu`, `play`, `levelup`, `dead`, `name`. Ein Neustart erfolgt über `reload_current_scene()`; der nächste Zustand wird in der statischen Variable `pending_state` übergeben.

## Lokal entwickeln

Voraussetzung: [Godot 4.x](https://godotengine.org/) (getestet mit 4.7.2).

```sh
brew install --cask godot        # macOS
godot --path .                   # Spiel starten
godot --path . --editor          # Im Editor öffnen
```

## Regressionstests

Die Tests laufen ohne zusätzliche Pakete und ohne die gespeicherten Spielstände
zu verändern:

```sh
godot --headless --path . --script tests/test_controller.gd
```

## Web-Export und Veröffentlichung (GitHub Pages)

Einmalig müssen die Godot-Export-Templates installiert sein (Editor: *Projekt → Exportieren → Templates verwalten*, oder manuell von den Godot-Releases).

```sh
godot --headless --export-release Web   # schreibt nach docs/
touch docs/.nojekyll
git add -A && git commit -m "Update web build" && git push
```

GitHub Pages ist auf Branch `main`, Ordner `/docs` konfiguriert. Der Export ist single-threaded (`thread_support=false`) und braucht daher keine speziellen COOP/COEP-Header. Die virtuelle Tastatur für die Namenseingabe auf Mobilgeräten ist im Preset aktiviert.

## Ideen für später

- Mehrere Waffen und Gegnertypen, Bosse
- Sprites, Animationen, Sound und Musik
- Aufteilung in mehrere Szenen und Skripte
- Native Mobile-Exports (Android/iOS)
- Globale Online-Bestenliste
