# Orchestra Scenario Folder Structure

## Overview

This file summarizes the Orchestra scenario folder layout and highlights the configuration values that the `Validate-Scenarios` script inspects. Scenario folders are organized by scenario name and contain XML configuration artifacts without file extensions. In folder mode, the script accepts either a directory that contains scenario folders or a direct path to a single scenario folder. The script can optionally filter validations to specific category codes (for example: ST, PM), filter scenario folder names or PSC file names, and switch between folder and PSC validation modes.

## Scenario root layout

- The scenario name is the folder name.
- Scenario folders contain XML configuration files with **no extension** and the following prefixes:
  - `ProcessModell_*`
  - `Channel_*`
  - `MessageMapping_*`
- Each XML file includes a matching `.prop` file with key/value pairs.

## PSC file

A `.psc` file is a zipped scenario folder (the folder contents, not the folder itself). When `Validate-Scenarios` runs in PSC mode (or when PSC inspection is enabled in folder mode), it opens `.psc` archives and validates the same `ProcessModell_*`, `Channel_*`, and `MessageMapping_*` entries contained inside, skipping entries that include file extensions (such as `.prop`).

## Regex Guard checks (`RG`)

- `Validate-Scenarios` also runs regex-based inspections against `ProcessModell_*` and `MessageMapping_*` contents. Matches are reported as category `RG` (Regex Guard) so they can be toggled with `-ErrorCategories` like the other categories.
- Regex rules live inside `Scripts/Validate-Scenarios/Validate-Scenarios.ps1` (no external config) and each rule specifies which artifact types it applies to.
- The initial rule flags `addBuKey(...SUBFL_stage)` usage (issue code `RG:nls`) to highlight non-local SUBFL stage calls.
- Description field exception codes do not suppress RG warnings; exclude RG via `-ErrorCategories` when you must temporarily ignore these findings.

## Scenario usage feature scan notes

`Show-ScenarioUsages` scans scenario folders similarly to `Validate-Scenarios` (root folder or direct scenario folder path) and evaluates predefined usage codes against scenario artifacts. Current checks include ErrorHandling references in `ProcessModell_*`, legacy `SUBFL.Log` usage in scenario files, and one-shape/Transmission message mapping markers in `MessageMapping_*`. The script supports filtering by scenario name, feature code, and feature type (Desired, Information, Warning), and can optionally print per-hit evidence paths via `-Evidence` (off by default).

## Process model files (`ProcessModell_*`)

Process model files are XML documents named `ProcessModell_*` (no extension).

XML root name: `ProcessModel`.

Each configuration XML supports a `description` element directly below the root. Validation can read exception codes from this description to allow deviations from the default rules. Default values typically omit explicit description codes but are still valid.

Validation reads the following fields:

- `/ProcessModel/name`: Process model name.
- `/ProcessModel/processObjects/EventStart/trigger/isDurable`: `true`/`false` for persistent vs. transient signal input.
- `/ProcessModel/isPersistent`: `true`/`false` for persistent vs. volatile/volatile_with_recovery mode.
- `/ProcessModel/volatilePoicy`: `1`/`0` for volatile_with_recovery vs. volatile.
- `/ProcessModel/redeployPolicy`: `1`/`0` for restart vs. abort on redeployment.
- `/ProcessModel/manualRestart`: `true`/`false` for manual restart enablement.
- `/ProcessModel/businessKeys/Property`: Business key entries; validation flags counts above the configured maximum.
- `/ProcessModel/isFifo`: `true`/`false` for FIFO scheduling.
- `/ProcessModel/isGroupedFifo`: `true`/`false` for grouped FIFO scheduling.
- `/ProcessModel/bestEffortLimit`: Numeric scheduling limit.
- `/ProcessModel/pipelineMode`: `true`/`false` for pipeline mode.
- `/ProcessModel/groupField`: Grouping field when scheduling is parallel grouped.

`Create-ProcessModelOverview` additionally reads:

- `/ProcessModel/ID`, `/ProcessModel/revisionNumber`, and `/ProcessModel/processSenarioID` for model metadata.
- `/ProcessModel/properties/Property` to list process variables and process-level INPUT/OUTPUT/IN_OUT parameters.
- `/ProcessModel/businessKeys/Property` to list business keys and types.
- `/ProcessModel/processObjects/*` including `inAssignments`, `outAssignments`, and shape-level `parameters`/`properties`/`trigger/parameters`.
- `/ProcessModel/edges/*`, `/ProcessModel/processEdges/*`, `/ProcessModel/sequenceFlows/*`, and `/ProcessModel/EdgeSequence` to list outgoing gateway edge conditions and optional edge display names, including else branches when no edge expression exists.
- Property and business key type metadata from optional child node `type`; missing type nodes are treated as empty values.
- Element scripts and expressions (`script`, `sourceExpr/expression`, edge expressions, labels) to support optional unused-variable detection.
- Overview reports default to `<script folder>/Output` unless `-OutputFolder` is supplied.
- Type values in the overview output use the type name text only (for example `string`).
- Element headings use compact `[Type, ElementID]` formatting.
- Input assignments, output assignments, and parameters are merged into one per-element detail table with columns `Name`, `Type`, `Usage`, `Input Expression`, and `Output Expression`.
- Assignment and parameter rows are normalized to arrays so single-row sections are handled consistently under strict mode.
- Elements without assignments, parameters, or gateway edges are handled as empty collections so overview generation does not fail under strict mode.

Scheduling shorthand (used in naming conventions):

- `p`: Parallel unbounded (`isFifo:false`, `isGroupedFifo:false`, `bestEffortLimit:0`, `pipelineMode:false`)
- `p#`: Parallel with limit (`isFifo:false`, `isGroupedFifo:false`, `bestEffortLimit:#`, `pipelineMode:false`)
- `pg`: Parallel grouped (`isFifo:true`, `isGroupedFifo:true`, `bestEffortLimit:0`, `pipelineMode:false`)
- `s`: Sequential (`isFifo:true`, `isGroupedFifo:false`, `bestEffortLimit:0`, `pipelineMode:false`)
- `pi`: Pipeline mode (`isFifo:true`, `isGroupedFifo:false`, `bestEffortLimit:0`, `pipelineMode:true`)

## Channel files (`Channel_*`)

Channel files are XML documents named `Channel_*` with no extension. XML root names vary by channel type.

Each channel XML supports a `description` element directly below the root. Validation can read exception codes from this description to allow deviations from the default rules.

Validation reads channel fields from the document root regardless of the specific channel type:

- `/*/name`: Channel name.
- `/*/numberOfInstances`: Concurrency count (when available).
- `/*/root-name`: Channel XML root name used for type-specific ST validation exclusions.

A channel is considered non-concurrent when `numberOfInstances` is `1`. ST validation is skipped for the following channel root names:

- `emds.epi.impl.adapter.tcp.mllp.MLLPConfigInbound`
- `emds.epi.impl.adapter.http.inbound.HttpAdapterGeneralPostConfig`

Sequential channels are allowed when all process models in the same scenario use sequential scheduling (`isFifo:true`, `isGroupedFifo:false`, `bestEffortLimit:0`, `pipelineMode:false`).

## Message mapping files (`MessageMapping_*`)

XML root name: `emds.mapping.proc.MappingScript`.

Each mapping XML supports a `description` element directly below the root. Validation can read exception codes from this description to allow deviations from the default rules.

Validation reads:

- `/emds.mapping.proc.MappingScript/name`: Mapping name.
- `/emds.mapping.proc.MappingScript/parallelExecution`: `true`/`false` concurrency flag.

Mappings are flagged when `parallelExecution` is not `true`.

Sequential mappings are allowed when all process models in the same scenario use sequential scheduling (`isFifo:true`, `isGroupedFifo:false`, `bestEffortLimit:0`, `pipelineMode:false`).

## Naming conventions

- **PM** Process Model
  - **PM** Process Mode
    - `v`: Volatile
    - `vr`: Volatile with recovery
    - `p`: Persistent
- **RS** Redeployment Strategy
  - `a`: Abort running processes
  - `r`: Restart after redeployment
- **MR** Manual Restart
  - `e`: Enabled
  - `d`: Disabled
- **SC** Scheduling
  - `p`: Parallel unbounded
  - `p#`: Parallel with limit #
  - `pg`: Parallel grouped
  - `s`: Sequential
  - `pi`: Pipeline mode
- **BK** Business Keys
  - `#`: Maximum allowed BKs (script-configured threshold)
- **SI** Input Signal
  - `p`: Persistent subscription
  - `t`: Transient subscription

- **CH** Channel
  - **ST** Resource usage strategy
    - `p`: Parallel execution
    - `s`: Sequential execution

- **MM** Message Mapping
  - **ST** Resource usage strategy
    - `p`: Parallel execution
    - `s`: Sequential execution

Default naming expectations (documented even when not validated):

- **PM**: `vr` (volatile with recovery)
- **RS**: `r` (restart after redeployment)
- **MR**: `e` (manual restart enabled)
- **SC**: `p` (parallel unbounded scheduling)
- **BK**: `#` (up to the script-configured maximum)
- **SI**: `p` (persistent subscription)
- **CH/ST**: `p` (parallel execution)
- **MM/ST**: `p` (parallel execution)

## Description-based exceptions

Validation reads optional codes embedded in the `description` text (for example: `PM:v; RS:a; SC:p75`). Codes can appear anywhere in the description and multiple codes can be listed. Only codes that align to validation checks are considered; unsupported codes such as `SC` are ignored.

Supported exception codes:

- **PM** Process Mode (`v`, `vr`, `p`)
- **RS** Redeployment Strategy (`a`, `r`)
- **MR** Manual Restart (`e`, `d`)
- **SI** Input Signal (`p`, `t`)
- **ST** Resource usage strategy (`p`, `s`) for channels and mappings
- **BK** Business key maximum (`#`)

When the script finds a non-default configuration that matches an exception code, it suppresses the entry by default and can optionally list it with an "exception configured" note.

Validation now reports progress while scanning folder files and PSC archive entries.

## Dedicated script usage documentation

A dedicated German usage page for `Validate-Scenarios` is maintained next to the script at `Scripts/Validate-Scenarios/Validate-Scenarios.md`. It describes operational intent, default values, allowed alternatives, and exception documentation workflow for Confluence reuse.

## Orchestra git working copy notes

Orchestra scenario working copies often contain local machine artifacts that should stay untracked.
For repositories handled by `Handle-OrchestraGit`, `.git/info/exclude` is ensured to contain at least:

- `/.orc.cred`
- `/association.map`
- `/lock`
- `/*.local`
- `/TestEnvironment*`

This keeps local runtime files out of `git status` without requiring repository-level `.gitignore` changes.
`Reset` aligns to upstream with `git reset --hard` and also removes untracked files via `git clean -fd`.
`Clean` untracks files that are already tracked but now match `.git/info/exclude` patterns.
Pending-change summaries show short counts for tracked (`c`) and untracked (`u`) files and also show update availability when both states apply.
Status output includes a last-commit timestamp (`yyyy-MM-dd HH:mm:ss`) column before the tag column; when an update is available, the summary also includes the upstream commit timestamp in the same format.
When the current commit is not directly tagged, the status column shows the most recent reachable tag with a trailing `*`.

## Elastic export script notes

`Write-ElasticDataToDatabase` reads paged Elasticsearch results via the shared helper and stores selected SUBFL process/business-key fields in SQL Server. It defaults the ScenarioName wildcard to `*SUBFL*` and includes `BK.SUBFL_changeart` in the export. The SQL companion file creates `[dbo].[ElasticData]` with both text and XML storage for `BK.SUBFL_subid_list` to support future query scenarios.

## Script parameter conventions
- Repository scripts that expose both `StartDate` and `EndDate` can also accept `Timespan` as an alternative end-bound.
- `Timespan` accepts numeric minute values and PowerShell `TimeSpan` values.
- `Get-PatientInfo` defaults to the last 14 days ending at the current time when `StartDate`, `EndDate`, and `Timespan` are omitted.
- `Get-PatientInfo` also supports `ToClipboard` to place the report into the clipboard as plain text plus HTML (fixed-width) for email-friendly pasting.
- `Get-PatientInfo` supports `IncludeMSGID` to list MSGID values with their message dates per grouped output block.

## Orchestra log analysis notes

`Analyze-OrchestraLog` parses Orchestra server log entries and groups recurring warning/error statements across one or more log files.
For grouping stability, the script supports a settings file with `regex;replacement` normalization rules that are applied before aggregation.
The summary output tracks first/last occurrence, count, severity, flattened statement text, and the first stacktrace line.

## Deployment status overview notes

`Get-DeploymentInfo` derives scenario state indicators from `active` and `persistentSubcription` values (with `serviceState` fallback for older responses) and keeps version comparison coloring limited to the displayed version numbers. `OnlyDifferences` now also keeps rows where a scenario is missing on one or more compared servers. Version output now keeps fixed-width alignment while replacing numeric leading zeros with spaces.
Landscape mode now materializes per-server landscape rows as a plain object array before storing them in the server map to avoid type-mismatch assignment errors during landscape comparisons.

## HL7 message send notes

`Send-HL7Message` sends HL7 payloads via MLLP using `-Protocol Tcp`, `-Protocol Tls`, or `-Protocol TlsWithCertificate` with configurable wire encoding. It supports file-based input (`-Path`) and dynamic request creation (`-Message A19` plus `-AID`, optional `-Sender`), prints the outbound request in color, and can continue despite TLS certificate policy errors when `-IgnoreTlsError` is used (warnings are still written). Replies are extracted from MLLP framing and either printed with colorized HL7 separators (`|`, `^`, `~`, `\`, `&`) or saved as UTF-8 via `-ResponsePath`; if no response arrives, the script now emits an explicit error with protocol guidance.

## Elastic resend operation notes

`Resend-FromElastic` supports operational SUBFL replay workflows by querying Elasticsearch with stage/category/MSGID filters, keeping only the oldest hit per BusinessCaseId/MSGID, and replaying payloads in batch, all-at-once, or interactive single-step mode with keyboard controls (P/R/S/X) shown in the processing progress bar while records are running. It can perform dry-run validation via `Action Test`, write per-record curl POST commands via `Mode Curl` (output file in `OutputDirectory`, no curl line console echo), writes timestamped success/error logs, reads resend endpoint definitions from `targets.csv`, tab-completes `Target` values from CSV `Name` entries, and can emit SourceInfo subscription filters through `TargetParty` and `TargetSubId`. Optional `Replacements` pairs allow regex-based search/replace updates on `MessageData1` and outgoing business-key values before replay. Multi-value filter parameters also normalize comma-separated input into distinct values so array filters apply as Elasticsearch OR terms. The script now initializes `System.Xml.Linq` explicitly so envelope cleanup remains available in hosts where the assembly is not preloaded. Running the script without explicit parameters now prints the detailed help page and exits without executing a query. Execution with parameters still requires at least one explicit business/date filter argument (for example StartDate/EndDate, ScenarioName, ProcessName, CaseNo, PatientId, SubId, MSGID/BusinessCaseId, Stage, Category, Subcategory, HcmMsgEvent); `Instance`, `Environment`, or `WorkflowPattern` alone are rejected and the script help is shown.


## Cato unit extraction notes

`Python-ExtractCatoUnitsForElastic` reads active Cato subscription XML payloads from `OrchEsbWskConfiguration`, extracts `Condition` entries where `locator="LST_KST"`, and writes NDJSON output with one row per `oe` plus derived `einrichtung` for Elasticsearch ingestion with `typ` fixed to `ADT`. The script targets Python 3.9.25 (or newer), fails with clear guidance when `pyodbc` or unixODBC runtime libraries are unavailable, and validates SQL Server ODBC drivers before connecting (prefers Driver 18, falls back to Driver 17).

## PatAuskunft helper script note

`Call-PatAuskunft` sends SOAP `GetData` requests to PatAuskunft and decodes the embedded XML response payload for console inspection. It supports environment-based endpoint selection, stores credentials in a user-scoped CLIXML file beside the script, allows all currently documented result names as parameter input, and defaults `Resultfilter` to the highest available version per selected result unless explicitly provided.

## PatAuskunft helper notes

`Call-PatAuskunft` prints decoded SOAP result XML with colorized output in the console to make element tags, attribute names/values, text nodes, and namespace prefixes easier to distinguish during manual checks.

## Deployment info script notes

`Get-DeploymentInfo` supports `Mode Version` for side-by-side scenario version checks and `Mode Landscape` for side-by-side landscape value checks (`VALUE`, `TYPE`, `URL`, `User`, `Proxy`, plus derived database `Server` and `DatabaseName`). Landscape mode supports `LandscapeName` filtering, `LandscapeIgnoreList` exclusion (default `ee_orch_instance`), type icons, and `OnlyDifferences` behavior that compares only derived database server/database fields.
