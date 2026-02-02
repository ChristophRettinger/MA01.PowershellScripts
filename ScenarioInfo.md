# Orchestra Scenario Folder Structure

## Overview

This file summarizes the Orchestra scenario folder layout and highlights the configuration values that the `Validate-Scenarios` script inspects. Scenario folders are organized by scenario name and contain XML configuration artifacts without file extensions. The script can optionally filter validations to specific category codes (for example: ST, PM).

## Scenario root layout

- The scenario name is the folder name.
- Scenario folders contain XML configuration files with **no extension** and the following prefixes:
  - `ProcessModell_*`
  - `Channel_*`
  - `MessageMapping_*`
- Each XML file includes a matching `.prop` file with key/value pairs.

## PSC file

A `.psc` file is a zipped scenario folder (the folder contents, not the folder itself).

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
- `/*/numberOfInstances`: Concurrency count.

A channel is considered non-concurrent when `numberOfInstances` is `1`.

## Message mapping files (`MessageMapping_*`)

XML root name: `emds.mapping.proc.MappingScript`.

Each mapping XML supports a `description` element directly below the root. Validation can read exception codes from this description to allow deviations from the default rules.

Validation reads:

- `/emds.mapping.proc.MappingScript/name`: Mapping name.
- `/emds.mapping.proc.MappingScript/parallelExecution`: `true`/`false` concurrency flag.

Mappings are flagged when `parallelExecution` is not `true`.

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
