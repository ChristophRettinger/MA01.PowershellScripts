# MA01 PowerShell Scripts

This repository contains a collection of scripts used within the MA01 environment, primarily PowerShell. PowerShell is the default unless a different language is explicitly requested; Python exceptions use a `Python-` prefix for both folder and script file names.

## Scripts

All scripts are located under the `Scripts` folder, each in its own subfolder named after the script (without the `.ps1` extension).

- **Copy-OperationData.ps1** - Transfers DataStore rows into OrchestraOperationData using resumable batches.
- **Find-MissingAdmIds.ps1** - Compares ADM changelog IDs with Elasticsearch results and outputs missing IDs.
- **Find-MissingMedarchivIds.ps1** - Compares changelog data with Elasticsearch to find missing Medarchiv records.
- **Get-AdmKavideErrors.ps1** - Collects and summarizes Kavide scenario errors from Elasticsearch with per-case details.
- **Get-ChatProperties.ps1** - Selects specific chat metadata fields and outputs a simplified JSON file.
- **Get-DeploymentInfo.ps1** - Queries Orchestra OrchDyn APIs across one or more servers to display scenario versions (Version mode) or landscape configuration properties (Landscape mode) with column-aligned, color-coded multi-server comparison. Credentials are stored per server as CLIXML.
- **Get-OrchestraErrors.ps1** - Aggregates failed Orchestra scenarios from Elasticsearch and optionally exports normalized error XML.
- **Get-OrchestraLogSummary.ps1** - Parses Orchestra log files, groups warning/error entries by normalized text, and summarizes first/last occurrence and count; supports regex-based normalization rules for grouping.
- **Get-PatientInfo.ps1** - Retrieves SUBFL HCM messages for a patient or case, exports structured JSON, can optionally list MSGID/date pairs per group, and can copy fixed-width report output to the clipboard for email-friendly sharing.
- **Get-RagMetadataSummary.ps1** - Summarizes RAG usage metadata from JSON and reports statistics plus field frequencies.
- **Invoke-ElasticResend.ps1** - Queries SUBFL records from Elasticsearch by date range and WorkflowPattern, keeps the oldest hit per MSGID, and supports resend/replay to configured HTTP targets. Optional regex replacements for payload and business keys; curl command export; ShowQuery action to print the request body without executing.
- **Invoke-OrchestraGit.ps1** - Scans Orchestra git repositories, ensures required local excludes, reports fixed-width status lines with last-commit timestamp (`yyyy-MM-dd HH:mm:ss`), tag, pending and update indicators, and supports status/update/pull/reset/clean actions.
- **Invoke-PatAuskunft.ps1** - Calls the PatAuskunft SOAP service for case-related identifiers, stores per-user credentials locally via CLIXML, uses built-in result/version metadata to default to the newest available result version, and prints decoded response XML with colorized tags, attributes, text, and namespaces.
- **New-ProcessModelOverview.ps1** - Parses ProcessModell_* XML files and generates Markdown overviews covering metadata, variables, business keys, element detail rows, and gateway edge conditions; supports single-file and folder modes with optional unused-variable analysis.
- **Resolve-HostNames.ps1** - Resolves IP addresses from a CSV file to host names and writes the enriched CSV.
- **Send-HL7Message.ps1** - Sends HL7 payloads over MLLP from file or dynamic query input (`-Message A19`), supports `Tcp`, `Tls`, or `TlsWithCertificate`, colorizes request/response output, and can continue after TLS certificate warnings with `-IgnoreTlsError`.
- **Show-ScenarioUsages.ps1** - Scans scenario folders and reports predefined usage/feature codes (filterable by code and type) based on ProcessModell_*, MessageMapping_*, and other scenario files.
- **Start-HttpListener.ps1** - Runs a lightweight HTTP/HTTPS listener that logs inbound requests.
- **Test-Connections.ps1** - Checks TCP connectivity for CSV-listed hosts and records results with resolved IPs.
- **Test-Scenarios.ps1** - Validates scenario folders or PSC archives for process model, channel, and mapping configuration rules; supports optional mode/category/name filters, sequential-scenario detection, and `RG` (Regex Guard) checks for disallowed constructs; writes a plain-text report when `-OutputDirectory` is supplied.
- **Write-ElasticToDatabase.ps1** - Reads SUBFL Elasticsearch records for a date range and writes selected MSGID/process/business-key fields (including change type) into SQL Server. Includes SQL templates for table creation and missing-output checks by MSGID/subid.
- **Python-ExtractCatoUnitsForElastic.py** - Reads active Cato subscriptions from SQL Server, extracts `LST_KST` units from subscription XML, and writes one NDJSON row per `oe` (including derived `einrichtung`) for Elasticsearch pickup with `typ` set to `ADT`.
- **install.sh** (in `Scripts/Python-ExtractCatoUnitsForElastic`) - Installs root crontab execution at `06:34` daily for the Cato export script and configures log rotation for `/var/log/cato_betr`.

## Shared utilities

- **Scripts/Common/ElasticSearchHelpers.ps1** - Hosts `Invoke-ElasticScrollSearch` (scroll queries with aggregated hits and page-progress callbacks), `Resolve-ElasticCredential` (CLIXML-based API key storage), `Get-ElasticSourceValue` (dotted-path field access), and `Resolve-EffectiveTimespan` (converts a number, TimeSpan, or string to a TimeSpan with a configurable default). Dot-sourced by all Elasticsearch scripts.
- **Scripts/Common/ServerConfig.ps1** - Provides `Get-ServerConfig`, a cached loader for `ServerConfig.psd1`. Returns the full infrastructure hashtable (Elasticsearch URLs, SQL Server connections, Orchestra server list, PatAuskunft endpoints, Medarchiv database mappings).

## Documentation references

- **SubflElasticInfo.md** - Overview of Subscription Flow (SUBFL) terminology plus how SUBFL scenarios log to Elasticsearch, including the specific fields and filters leveraged by the SUBFL-related scripts in this repository.
- **ScenarioInfo.md** - Reference for Orchestra scenario folder structure, including expected file naming patterns and scenario-related configuration notes drawn from the scripts.
- **Scripts/Test-Scenarios/Test-Scenarios.md** - German usage documentation for Test-Scenarios, including defaults, exception handling, and review intent.

## Shared date-range behavior

Scripts that expose `StartDate`/`EndDate` can support `Timespan` as an alternative to `EndDate`. `Timespan` accepts either a number (minutes) or a PowerShell `TimeSpan` value. `Get-PatientInfo` defaults to the last 14 days ending at the current time when `StartDate`, `EndDate`, and `Timespan` are all omitted.
