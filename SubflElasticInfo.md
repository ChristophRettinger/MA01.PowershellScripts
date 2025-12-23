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

## Script-observed SUBFL elastic usage
- **Process-MissingADM** queries `BK.SUBFL_sourceid` in Elasticsearch for `BK.SUBFL_messagetype:AdmRecord` and `BK.SUBFL_stage:Input` in the `production` environment, expanding the time range around the DB window. It maps `BK.SUBFL_sourceid` to the ADM `CL_ID` range and uses `@timestamp` (or a caller-specified field) for filtering.【F:Scripts/Process-MissingADM/Process-MissingADM.ps1†L9-L13】【F:Scripts/Process-MissingADM/Process-MissingADM.ps1†L183-L200】
- **Process-MissingMedarchiv** compares `CL_ID_BIG` values against Elasticsearch by filtering `BK.SUBFL_sourceid` and `BK.SUBFL_sourcedb` (mapped from the database name) within the selected time range, reusing the shared scroll helper.【F:Scripts/Process-MissingMedarchiv/Process-MissingMedarchiv.ps1†L4-L11】【F:Scripts/Process-MissingMedarchiv/Process-MissingMedarchiv.ps1†L235-L266】
- **Evaluate-AdmKavideErrors** focuses on scenario `ITI_SUBFL_KAVIDE_speichern_v01_3287`, first pulling `WorkflowPattern:ERROR` events to find case numbers (`BK._CASENO`), then querying full events per case. It summarizes successes grouped by `BK.SUBFL_subid`, `BK.SUBFL_category`, and `BK.SUBFL_subcategory`, reporting `BusinessCaseId` (MSGID) and `BK._STATUS_TEXT` details for each error.【F:Scripts/Evaluate-AdmKavideErrors/Evaluate-AdmKavideErrors.ps1†L5-L23】【F:Scripts/Evaluate-AdmKavideErrors/Evaluate-AdmKavideErrors.ps1†L169-L183】
- **Add-HostNames** defaults to resolving hostnames from the `BK.SUBFL_source_host` field when enriching CSV data.【F:Scripts/Add-HostNames/Add-HostNames.ps1†L13-L34】
