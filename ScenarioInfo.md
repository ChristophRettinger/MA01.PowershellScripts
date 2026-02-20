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
Pending-change summaries show short counts for tracked (`c`) and untracked (`u`) files and now also show update availability when both states apply.
When the current commit is not directly tagged, the status column shows the most recent reachable tag in parentheses.

## Script parameter conventions
- Repository scripts that expose both `StartDate` and `EndDate` can also accept `Timespan` as an alternative end-bound.
- `Timespan` accepts numeric minute values and PowerShell `TimeSpan` values.
- If neither `EndDate` nor `Timespan` is supplied, a default 15-minute window is used from `StartDate`.

## Orchestra log analysis notes

`AnalyzeOrchestraLog` parses Orchestra server log entries and groups recurring warning/error statements across one or more log files.
For grouping stability, the script supports a settings file with `regex;replacement` normalization rules that are applied before aggregation.
The summary output tracks first/last occurrence, count, severity, flattened statement text, and the first stacktrace line.

