# SUBFL Elasticsearch specifics

This note consolidates how Subscription Flow (SUBFL) scenarios log to Elasticsearch and the fields already used by scripts in this repository.

## Orchestra building blocks (SUBFL context)
- **Scenario**: Deployable unit with a defined name that handles one task in the flow.
- **Process Model**: Workflow implementation inside a scenario (GUI + Java logic).
- **Signal**: Input queue that links process models; one model publishes to a signal, another consumes it.

## SUBFL domain terms
- **Flow / Workflow**: Business process that chains multiple scenarios (process models).
- **Subscription**: XML definition stored in the DB that specifies matching conditions and resulting actions. Identified by **SubscriptionId**.
- **Business Keys**: Values extracted from the data (e.g., patient ID, case number) stored in Elasticsearch with the `BK.` prefix.
- **MSGID / BusinessCaseId**: Identifier assigned by the input scenario to each incoming record. Combined with the SubscriptionId it uniquely identifies a SUBFL flow.

## Elastic logging patterns and fields
- `WorkflowPattern` marks record types written by a scenario: `IN` and `OUT` for normal flow, `ERROR` for failures, and `REQ_RESP` for explicit request/response logging.
- Stages: `BK.SUBFL_stage` is `Input` for inbound scenarios, `Process` for mapping/processing scenarios, and `Output` for the final senders. `BK.SUBFL_outputtype` specifies the output channel for senders.
- Input scenarios always set `BK.SUBFL_stage:Input` and a `BK.SUBFL_messagetype` for the inbound data (e.g., `AdmRecord`), and they emit one Elasticsearch record per received message with the `MSGID`/`BusinessCaseId`. They invoke the subscription resolver next.
- Subscription scenarios resolve matches but currently do **not** write Elasticsearch entries for performance reasons.
- Processing/output scenarios extend the flow; mapping steps use `BK.SUBFL_stage:Process` and final senders use `BK.SUBFL_stage:Output` plus `BK.SUBFL_outputtype`.
- Host metadata defaults to `BK.SUBFL_source_host` (see Add-HostNames).

## Known SUBFL Elastic fields
- **BK._CASENO** (also called **AID**): case number such as `90120311    93013630` with pattern `\d{8}    \d{8}`. Equivalent in meaning to the other CASENO variations.
- **BK._CASENO_BC** (Barcode MAC): alternative case identifier such as `1JDLRYBKK` with pattern `\w{9}`.
- **BK._CASENO_ISH** (Fallzahl): case number variant such as `7622000264` with pattern `\d{10}`.
- **BK._PID**: patient identifier shown as **AID** in script output to highlight the patient reference alongside case identifiers.
- **BK._PID_ISH** (also called **PID**, shown as **Fallzahl** in script output): patient identifier such as `0000869517` with pattern `\d{10}`.
- **BK._CASETYPE**: Either S for stationary (inbound) or A or ambulatory (outbound).
- **BK.SUBFL_category**: identifies the category of data (e.g., `CASE`, `PATIENT`, `DIAGNOSIS`).
- **BK.SUBFL_changeart**: denotes change type (`INSERT`, `UPDATE`, or `DELETE`).
- **BK.SUBFL_subcategory**: further refines the category (e.g., `Visit`, `Admission`, `Transfer`); only present for some categories.
- **BK.SUBFL_party**: receiver name that groups subscriptions logically and can be used for filtering.
- **BK.SUBFL_subid**: subscription identifier.
- **BK.SUBFL_workflow**: workflow name.
- **BK.SUBFL_sourceid**: source record identifier, such as a database primary key or HCM MessageID.
- **BK._ELGA_RELEVANT**: `true` or `false`, indicating whether a record may be sent to the Sense system.
- **BK._MOVENO**: movement identifier within a case, following the pattern `\d{5}`.

The different CASENO values (`BK._CASENO`, `BK._CASENO_BC`, and `BK._CASENO_ISH`) represent the same underlying case, and most logs include all of them. When producing script output, display `BK._PID` as **AID** and `BK._PID_ISH` as **Fallzahl** to keep patient and case identifiers aligned.

## Date-range parameters in SUBFL scripts
- SUBFL scripts in this repository that expose `StartDate`/`EndDate` also accept `Timespan` as an alternative to `EndDate`.
- `Timespan` supports either a numeric minute value or a PowerShell `TimeSpan` input.
- If neither `EndDate` nor `Timespan` is provided, the scripts apply a default range of 15 minutes from `StartDate`.

## SQL export field set

`Write-ElasticDataToDatabase` exports a subset of SUBFL fields into SQL Server for downstream analysis:

- `MSGID` (fallback: `BusinessCaseId`)
- `ScenarioName`
- `ProcessName`
- `@timestamp` (stored as `ProcesssStarted`)
- `BK.SUBFL_changeart`
- `BK.SUBFL_category`
- `BK.SUBFL_subcategory`
- `BK._HCMMSGEVENT`
- `BK.SUBFL_subid`
- `BK.SUBFL_subid_list` (stored both as comma-separated text and as XML `<subids><subid>...</subid></subids>`)

For downstream completeness checks, use `Scripts/Write-ElasticDataToDatabase/Write-ElasticDataToDatabase.MissingProcesses.sql` to identify MSGIDs with no outputs and MSGIDs with only partial outputs compared to `BK_SUBFL_subid_list`.

## Elastic resend script notes

`Resend-FromElastic` queries SUBFL records through `Invoke-ElasticScrollSearch`, keeps only the oldest hit per BusinessCaseId/MSGID, and can summarize result ranges per `ScenarioName`, prepare/send replay requests to HTTP targets defined in a local CSV, or generate per-record curl POST commands via `Mode Curl` (written to an output file). For replay, it sends `MessageData1` as UTF-8 body, derives `SourceInfoMsg` from `MessageData2` when available, adds optional `SubscriptionFilterParty`/`SubscriptionFilterId` elements from `TargetParty` and `TargetSubId`, and builds `BuKeysString` from `BK.*` fields except SUBFL control keys.
