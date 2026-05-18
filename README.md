# MA01 PowerShell Scripts

This repository contains a collection of scripts used within the MA01 environment, primarily PowerShell. PowerShell is the default unless a different language is explicitly requested; Python exceptions use a `Python-` prefix for both folder and script file names.

## Scripts

All scripts are located under the `Scripts` folder, each in its own subfolder named after the script (without the `.ps1` extension).

- **Add-HostNames.ps1** - Resolves IP addresses from a CSV file to host names and writes the enriched CSV.
- **Analyze-RagMetadata.ps1** - Summarizes RAG usage metadata from JSON and reports statistics plus field frequencies.
- **Analyze-OrchestraLog.ps1** - Parses Orchestra log files, groups warning/error entries, summarizes first/last occurrence and count, and supports regex-based normalization rules for grouping.
- **Extract-ChatProperties.ps1** - Selects specific chat metadata fields and outputs a simplified JSON file.
- **Start-HttpListener.ps1** - Runs a lightweight HTTP/HTTPS listener that logs inbound requests.
- **Test-Connections.ps1** - Checks TCP connectivity for CSV-listed hosts and records results with resolved IPs.
- **Process-MissingADM.ps1** - Compares ADM changelog IDs with Elasticsearch results and outputs missing IDs.
- **Process-MissingMedarchiv.ps1** - Compares changelog data with Elasticsearch to find missing Medarchiv records.
- **Evaluate-OrchestraErrorsViaElastic.ps1** - Aggregates failed Orchestra scenarios from Elasticsearch and optionally exports normalized error XML.
- **Evaluate-AdmKavideErrors.ps1** - Collects and summarizes Kavide scenario errors from Elasticsearch with per-case details.
- **Get-PatientInfo.ps1** - Retrieves SUBFL HCM messages for a patient or case, exports structured JSON, can optionally list MSGID/date pairs per group, and can copy fixed-width report output to the clipboard for email-friendly sharing.
- **Handle-OrchestraGit.ps1** - Scans Orchestra git repositories, ensures required local excludes, reports fixed-width status lines with last-commit timestamp (`yyyy-MM-dd HH:mm:ss`), tag, pending and update indicators, and supports status/update/pull/reset/clean actions.
- **Validate-Scenarios.ps1** - Validates scenario folders (including a direct path to a single scenario folder) or PSC archives with optional mode/category/name filters, shows validation progress, and can write a text report; derives channel strategy from `numberOfInstances`, skips ST checks for selected channel root types, and allows sequential channel/mapping strategy when all process models in a scenario are sequential (ignores non-XML PSC entries). Emits `RG` (Regex Guard) warnings when ProcessModell_* or MessageMapping_* files match built-in regex rules such as `addBuKey(...SUBFL_stage)`.
- **Show-ScenarioUsages.ps1** - Scans scenario folders and reports predefined usage/feature codes (filterable by code and type) based on ProcessModell_*, MessageMapping_*, and other scenario files.
- **Send-HL7Message.ps1** - Sends HL7 payloads over MLLP from file or dynamic query input (`-Message A19`), supports `Tcp`, `Tls`, or `TlsWithCertificate`, colorizes request/response output, and can continue after TLS certificate warnings with `-IgnoreTlsError`.
- **Transfer-OperationData.ps1** - Transfers DataStore rows into OrchestraOperationData using resumable batches.
- **Get-DeploymentInfo.ps1** - Queries Orchestra OrchDyn APIs across one or more servers to display scenario versions (Version mode) or landscape configuration properties (Landscape mode) with column-aligned, color-coded multi-server comparison. Credentials are stored per server as CLIXML.
- **Call-PatAuskunft.ps1** - Calls the PatAuskunft SOAP service for case-related identifiers, stores per-user credentials locally via CLIXML, uses built-in result/version metadata to default to the newest available result version, and prints decoded response XML with colorized tags, attributes, text, and namespaces.
- **Create-ProcessModelOverview.ps1** - Parses ProcessModell_* XML files and creates Markdown overviews for model metadata, variables, business keys, merged element detail rows (`Name`, `Type`, `Usage`, `Input Expression`, `Output Expression`), and gateway outgoing edge conditions (including EdgeSequence-based paths and else branches), writing reports to the script-local `Output` folder by default.
- **Write-ElasticDataToDatabase.ps1** - Reads SUBFL Elasticsearch records for a date range and writes selected MSGID/process/business-key fields (including change type) into SQL Server. Includes SQL templates for table creation and missing-output checks by MSGID/subid.
- **Resend-FromElastic.ps1** - Queries SUBFL records from Elasticsearch, keeps only the oldest hit per BusinessCaseId/MSGID, supports grouped reporting, controlled resend/test replay, optional regex-based payload/business-key replacements, curl command export for configured HTTP targets, filters by WorkflowPattern (custom value or ErrorOnly shortcut), converts operator-supplied StartDate/EndDate from local time to UTC for `@timestamp` filtering, and offers a `ShowQuery` action to print the Elasticsearch request body without executing it.
- **Python-ExtractCatoUnitsForElastic.py** - Reads active Cato subscriptions from SQL Server, extracts `LST_KST` units from subscription XML, and writes one NDJSON row per `oe` (including derived `einrichtung`) for Elasticsearch pickup with `typ` set to `ADT`.
- **install.sh** (in `Scripts/Python-ExtractCatoUnitsForElastic`) - Installs root crontab execution at `06:34` daily for the Cato export script and configures log rotation for `/var/log/cato_betr`.

## Shared utilities

- **Scripts/Common/ElasticSearchHelpers.ps1** - Hosts `Invoke-ElasticScrollSearch` (scroll queries with aggregated hits and page-progress callbacks), `Resolve-ElasticCredential` (CLIXML-based API key storage), `Get-ElasticSourceValue` (dotted-path field access), and `Resolve-EffectiveTimespan` (converts a number, TimeSpan, or string to a TimeSpan with a configurable default). Dot-sourced by all Elasticsearch scripts.
- **Scripts/Common/ServerConfig.ps1** - Provides `Get-ServerConfig`, a cached loader for `ServerConfig.psd1`. Returns the full infrastructure hashtable (Elasticsearch URLs, SQL Server connections, Orchestra server list, PatAuskunft endpoints, Medarchiv database mappings).

## Documentation references

- **SubflElasticInfo.md** - Overview of Subscription Flow (SUBFL) terminology plus how SUBFL scenarios log to Elasticsearch, including the specific fields and filters leveraged by the SUBFL-related scripts in this repository.
- **ScenarioInfo.md** - Reference for Orchestra scenario folder structure, including expected file naming patterns and scenario-related configuration notes drawn from the scripts.
- **Scripts/Validate-Scenarios/Validate-Scenarios.md** - German usage documentation for Validate-Scenarios, including defaults, exception handling, and review intent.

## Shared date-range behavior

Scripts that expose `StartDate`/`EndDate` can support `Timespan` as an alternative to `EndDate`. `Timespan` accepts either a number (minutes) or a PowerShell `TimeSpan` value. `Get-PatientInfo` defaults to the last 14 days ending at the current time when `StartDate`, `EndDate`, and `Timespan` are all omitted.
