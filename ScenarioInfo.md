# Orchestra Scenario Folder Structure

## Overview

This file describes the Orchestra scenario folder that contains the configuration artifacts for a single scenario. 

## Scenario root layout

- The scenario name is the folder name.
- Scenario folders contain XML configuration files with **no extension** and the following prefixes:
  - `ProcessModell_*`
  - `Channel_*`
  - `MessageMapping_*`
- Each XML file contains a matching .prop file with Key/Value pairs.

## PSC file

A .psc file is a zipped scenario folder (without the folder itself).

## Process model files (`ProcessModell_*`)

Process model files are XML documents named `ProcessModell_*` with no extension. 

Xml Root name: `ProcessModel`

- `/ProcessModel/name`: The name of the Process model.
- `/ProcessModel/processObjects/EventStart/trigger/isDurable`: true/false. If the Signal input is persistent (true) or transient (false).
- `/ProcessModel/isPersistent`: true/false. If the Process mode is persistent (true) or volatile/volatile_with_recovery (false).
- `/ProcessModel/volatilePoicy`: 1/0. If the Process mode is volatile (0) or volatile_with_recovery (1).
- `/ProcessModel/redeployPolicy`: 1/0. If the Redeployment strategy is set to abort (0) or restart (1).
- `/ProcessModel/manualRestart`: true/false. If the Manual restart is enabled.
- `/ProcessModel/businessKeys/Property`: The defined Business Keys of the Process model. Should not be much larger than 5.
The following settings define the **Scheduling**
- `/ProcessModel/isFifo`: true/false
- `/ProcessModel/isGroupedFifo`: true/false
- `/ProcessModel/bestEffortLimit`: numeric
- `/ProcessModel/pipelineMode`: true/false
- `/ProcessModel/groupField`: The field for grouping if scheduling is "Parallel grouped "
**SC** Scheduling
  - `p` Parallel unbounded - isFifo:false, isGroupedFifo:false, bestEffortLimit:0, pipelineMode:false
  - `p#` Parallel with limit # - isFifo:false, isGroupedFifo:false, bestEffortLimit:#, pipelineMode:false
  - `pg` Parallel grouped - isFifo:true, isGroupedFifo:true, bestEffortLimit:0, pipelineMode:false
  - `s` Sequential - isFifo:true, isGroupedFifo:false, bestEffortLimit:0, pipelineMode:false
  - `pi` Pipeline mode - isFifo:true, isGroupedFifo:false, bestEffortLimit:0, pipelineMode:true

## Channel files (`Channel_*`)

Channel files are XML documents named `Channel_*` with no extension. 

Xml Root name: depending on the type of channel

- `/./name`: The name of the Channel
- `/./numberOfInstances`: 1 or other number

A channel is considered non-concurrent when `numberOfInstances` is `1`.

## Message mapping files (`MessageMapping_*`)

Xml Root name: `emds.mapping.proc.MappingScript`

Message mapping files are XML documents named `MessageMapping_*` with no extension. The validation script checks:

- `/emds.mapping.proc.MappingScript/name`: The name of the Message Mapping
- `/emds.mapping.proc.MappingScript/parallelExecution`

Mappings are flagged when `parallelExecution` is not `true`.

## Naming convention

- **PM** Process Model
  - **PM** Process Mode
    - `v` Volatile
    - `vr` Volatile with recovery
    - `p` Persistent
- **RS** Redeployment Strategy
  - `a` Abort running processes
  - `r` Restart after redeployment
- **MR** Manual Restart
  - `e` Enabled
  - `d` Disabled
- **SC** Scheduling
  - `p` Parallel unbounded
  - `p#` Parallel with limit #
  - `pg` Parallel grouped
  - `s` Sequential
  - `pi` Pipeline mode
- **BK** Business Keys
  - `#` Max allowed BKs (default 5)
- **SI** Input Signal
  - `p` Persistent subscription
  - `t` Transient subscription

- **CH** Channel
  - **ST** Resourceusage Strategy
    - `p` Parallel execution
    - `s` Parallel execution

- **MM** Message Mapping
  - **ST** Resourceusage Strategy
    - `p` Parallel execution
    - `s` Parallel execution
