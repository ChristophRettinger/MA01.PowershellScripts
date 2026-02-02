# Orchestra Scenario Folder Structure

## Overview

This file summarizes the Orchestra scenario folder layout and highlights the configuration values that the `Validate-Scenarios` script inspects. Scenario folders are organized by scenario name and contain XML configuration artifacts without file extensions.

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

Validation reads channel fields from the document root regardless of the specific channel type:

- `/*/name`: Channel name.
- `/*/numberOfInstances`: Concurrency count.

A channel is considered non-concurrent when `numberOfInstances` is `1`.

## Message mapping files (`MessageMapping_*`)

XML root name: `emds.mapping.proc.MappingScript`.

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
