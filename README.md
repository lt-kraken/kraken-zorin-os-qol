# Zorin persoonlijke instellingen

Dit interactieve script zet gekozen persoonlijke Zorin-instellingen. Het is bedoeld voor herinstallaties en kan veilig opnieuw worden uitgevoerd.

## Uitvoeren

Start de configuratie:

```sh
bash setup-zorin.sh
```

Vink in het eerste scherm aan wat je wilt configureren. Onderdelen beginnen uitgevinkt; bestaande instellingen van niet-geselecteerde onderdelen blijven ongewijzigd. Als je audio-invoer of -uitvoer kiest, verschijnt een tweede scherm met de beschikbare PipeWire-profielen. Je ziet vooraf welke opties nu actief zijn.

Het script toont de volledige selectie en vraagt om bevestiging voordat het wijzigingen toepast. Je kunt op elk keuzescherm annuleren.

Controleer hetzelfde proces zonder wijzigingen:

```sh
bash setup-zorin.sh --dry-run
```

Het script vereist geen `sudo`. Het downloadt ontbrekende GNOME-uitbreidingen van extensions.gnome.org. Vanuit de Flatpak-terminal van VS Code gebruikt het `flatpak-spawn --host`; in een normale terminal voert het dezelfde opdrachten rechtstreeks op het hostsysteem uit.

## Wat wordt ingesteld

- **macOS-achtige bovenbalk:** behoudt de GNOME-bovenbalk en zet het Zorin-dock onderaan, gecentreerd en dynamisch; verbergt **System Menu** en **Date Menu** in het dock.
- **Windows-achtige screenshottoets:** behoudt `Print Screen` en koppelt `Super+Shift+S` aan de screenshotinterface.
- **Klembordgeschiedenis:** installeert Clipboard Indicator met `Super+V`, maximaal 25 items, favorieten als enige cachebestanden en afbeeldingscache uit.
- **Spotlight-achtige zoekfunctie:** installeert Search Light met `Super+Spatie`, opent op het scherm met de muisaanwijzer en toont een pictogram in de bovenbalk.
- **Audio beperken:** toont audio-uitvoer- en invoerprofielen afzonderlijk. Geselecteerde profielen blijven beschikbaar; de overige profielen op dezelfde kaarten worden uitgeschakeld. Per geluidskaart kan één profiel per richting worden gekozen. Het script behoudt de niet-geselecteerde richting waar een passend gecombineerd profiel beschikbaar is; ontbreekt zo'n profiel, dan stopt het vóór wijzigingen.

De onderdelen **Windows-achtige screenshottoets** en **macOS-achtige zoekfunctie** zijn onafhankelijk. Search Light verplaatst ook de sneltoets voor toetsenbordindeling wisselen naar `Super+Alt+Spatie`, zodat `Super+Spatie` beschikbaar is.

Audioapparaten worden tijdens de installatie op naam en profiel uit PipeWire ontdekt, niet op veranderlijke apparaatnummers. De extensies worden per GNOME-versie uit de officiële extensiecatalogus opgehaald.

## Back-ups en uitbreiden

Bij toepassen slaat het script eerst GNOME Shell-instellingen, sneltoetsen en de huidige PipeWire-audiostatus op onder `~/.local/state/zorin-setup/backups/`. Dit is een lokale veiligheidskopie; bewaar ook deze map en de scriptmap buiten de computer als je ze na een schone installatie wilt terugzetten.

Voeg toekomstige voorkeuren toe als afzonderlijke opties aan het eerste keuzescherm en pas ze alleen toe als ze zijn aangevinkt. Het script installeert geen Android-integratie en geen systeem-pakketten. Na het installeren van nieuwe GNOME-extensies kan afmelden en opnieuw aanmelden nodig zijn.