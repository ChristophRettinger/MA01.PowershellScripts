# Validate-Scenarios – Anwendungsdokumentation

## Zweck des Scripts

`Validate-Scenarios.ps1` stellt sicher, dass Orchestra-Scenarios konsistent mit den definierten Standardwerten betrieben werden.
Das Script existiert, um **Abweichungen sichtbar zu machen**, **Ausnahmen explizit zu dokumentieren** und damit eine bewusste Architektur-/Betriebsentscheidung zu erzwingen statt stiller, ungeprüfter Sonderfälle.

Damit unterstützt es konkret:

- technische Konsistenz über alle Scenarios,
- nachvollziehbare Ausnahmen direkt in `description`-Feldern.

## Ablageort

Der Ablageort des Scripts ist:

`\\vsma01.host.magwien.gv.at\ma01gat\GAT2\_Tools\Powershell\Validate-Scenarios.ps1`

## Was wird validiert?

Das Script validiert die Artefakttypen **ProcessModel**, **Channel** und **MessageMapping**.
Die dazugehörigen Dateimuster sind:

- ProcessModel-Dateien: `ProcessModell_*`
- Channel-Dateien: `Channel_*`
- MessageMapping-Dateien: `MessageMapping_*`

Prüfkategorien (`ErrorCategories`):

- `PM` (Process Mode)
- `RS` (Redeployment Strategy)
- `MR` (Manual Restart)
- `SI` (Input Signal)
- `BK` (Business Keys)
- `ST` (Resource usage strategy für Channel/Mapping)

## Pfadverhalten (`-Path`)

`-Path` kann auf unterschiedliche Strukturen zeigen:

- direkt auf **ein einzelnes Scenario-Verzeichnis**,
- auf einen Root-Ordner mit vielen Scenario-Ordnern, auch mit Unterordnern beliebiger Tief

Zusätzlich kann über `-Filter` auf Scenario-Namen (Folder-Mode) oder PSC-Dateinamen (PSC-Mode) eingeschränkt werden.

## Standardwerte (Defaults), Bedeutung und Alternativen

Die folgenden Default-Entscheidungen sind die Referenz für alle Scenarios.
Abweichungen sind möglich, müssen aber als Ausnahmen dokumentiert werden.

### Process Model

- **PM default: `vr`** (`volatile with recovery`)
  - `v`: `volatile` (ohne Recovery)
  - `vr`: `volatile with recovery`
  - `p`: `persistent`
- **RS default: `r`** (`restart on redeploy`)
  - `a`: `abort running processes`
  - `r`: `restart after redeployment`
- **MR default: `e`** (`manual restart enabled`)
  - `e`: enabled
  - `d`: disabled
- **SI default: `p`** (`persistent signal subscription`)
  - `p`: persistent subscription
  - `t`: transient subscription
- **BK default: `6`** (über Script-Parameter `MaxBusinessKeyCount`)
  - mögliche Werte: positive Ganzzahlen (z. B. `6`, `8`, `10`)

### Scheduling / Strategy

- **SC default: `p`** (`parallel unbounded scheduling`)
  - `p`: parallel unbounded
  - `p#`: parallel mit Limit `#`
  - `pg`: parallel grouped
  - `s`: sequential
  - `pi`: pipeline mode
- **ST default: `p`** (`parallel execution`)
  - `p`: parallel execution
  - `s`: sequential execution

Hinweise zur Herleitung von `ST`:

- Bei `Channel_*` wird `ST` aus `numberOfInstances` abgeleitet (`1` => `s`, sonst `p`).
- Bei `MessageMapping_*` wird `ST` aus `parallelExecution` abgeleitet (`false` => `s`, `true` => `p`).
- Sequential `ST:s` bei Channel/Mapping ist zulässig, wenn **alle** Process Models des Scenarios sequential sind (`isFifo:true`, `isGroupedFifo:false`, `bestEffortLimit:0`, `pipelineMode:false`).

## Script-Parameter (Usage)

### Standardaufruf

```powershell
.\Scripts\Validate-Scenarios\Validate-Scenarios.ps1
```

### Wichtige Parameter

- `-Path` (default `.`): Root-Ordner, einzelnes Scenario-Verzeichnis oder rekursiv zu scannender Bereich
- `-Mode` (default `Folder`): `Folder` oder `PSC`
- `-IncludePsc` (switch): prüft im `Folder`-Mode zusätzlich `.psc`
- `-Filter` (default `all`): Wildcard auf Scenario-Ordner bzw. PSC-Dateien
- `-ErrorCategories`: Teilmenge von `PM,RS,MR,SI,BK,ST`
- `-MaxBusinessKeyCount` (default `6`): BK-Schwellwert
- `-ShowExceptions` (switch): zeigt auch konfigurierte Ausnahmen
- `-Output`: schreibt Report in Datei/Ordner

### Beispielaufrufe

```powershell
# Alle Scenarios im Ordner prüfen
.\Scripts\Validate-Scenarios\Validate-Scenarios.ps1 -Path D:\Scenarios

# Direkt ein einzelnes Scenario-Verzeichnis prüfen
.\Scripts\Validate-Scenarios\Validate-Scenarios.ps1 -Path D:\Scenarios\ITI_SUBFL_Sense_senden_4292

# Nur BK und ST prüfen, BK-Limit auf 8
.\Scripts\Validate-Scenarios\Validate-Scenarios.ps1 -Path D:\Scenarios -ErrorCategories BK,ST -MaxBusinessKeyCount 8

# Nur PSC-Dateien prüfen
.\Scripts\Validate-Scenarios\Validate-Scenarios.ps1 -Path D:\Scenarios -Mode PSC
```

## Ausnahmen bewusst dokumentieren

Ausnahmen werden im `description`-Feld der jeweiligen Elementes hinterlegt, z. B.:

`PM:v; RS:a; ST:s; BK:8`

Die `description` darf zusätzlich beliebigen Freitext enthalten; das Script liest nur die unterstützten Key/Value-Codes.

Unterstützte Exception-Codes:

- `PM`: `v`, `vr`, `p`
- `RS`: `a`, `r`
- `MR`: `e`, `d`
- `SI`: `p`, `t`
- `ST`: `p`, `s`
- `BK`: numerischer Grenzwert

Wichtig:

- Nicht unterstützte oder fachlich nicht validierte Codes werden ignoriert.
- Ziel ist, dass jede Abweichung vom Default eine nachvollziehbare, explizite Entscheidung bleibt.

## Screenshots (Platzhalter)

- [SCREENSHOT-1: Konsolen-Output]
- [SCREENSHOT-2: Konsolen-Output mit `-ShowExceptions`]
- [SCREENSHOT-3: Beispiel `description` mit Exception-Codes]
