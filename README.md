# MA01 PowerShell Scripts

This repository contains a collection of PowerShell scripts used within the MA01 environment. Each script helps automate a specific operational or analysis task.

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
- **Get-PatientInfo.ps1** - Retrieves SUBFL HCM messages for a patient or case and exports structured JSON.
- **Handle-OrchestraGit.ps1** - Scans Orchestra git repositories, ensures required local excludes, reports fixed-width status lines with last-commit timestamp (`yyyy-MM-dd HH:mm:ss`), tag, pending and update indicators, and supports status/update/pull/reset/clean actions.
- **Validate-Scenarios.ps1** - Validates scenario folders (including a direct path to a single scenario folder) or PSC archives with optional mode/category/name filters, shows validation progress, and can write a text report; derives channel strategy from `numberOfInstances`, skips ST checks for selected channel root types, and allows sequential channel/mapping strategy when all process models in a scenario are sequential (ignores non-XML PSC entries).
- **Transfer-OperationData.ps1** - Transfers DataStore rows into OrchestraOperationData using resumable batches.
- **Create-ProcessModelOverview.ps1** - Parses ProcessModell_* XML files and creates Markdown overviews for model metadata, variables, business keys, merged element detail rows (`Name`, `Type`, `Usage`, `Input Expression`, `Output Expression`), and gateway outgoing edge conditions (including EdgeSequence-based paths and else branches), writing reports to the script-local `Output` folder by default.
- **Write-ElasticDataToDatabase.ps1** - Reads SUBFL Elasticsearch records for a date range and writes selected MSGID/process/business-key fields (including change type) into SQL Server. Includes SQL templates for table creation and missing-output checks by MSGID/subid.
- **Resend-FromElastic.ps1** - Queries SUBFL records from Elasticsearch with flexible filters and supports grouped query reporting or controlled resend/test replay to configured HTTP targets.

## Shared utilities

- **Scripts/Common/ElasticSearchHelpers.ps1** - Hosts `Invoke-ElasticScrollSearch`, a reusable helper that issues scroll queries, aggregates all hits, surfaces detailed error information, and optionally reports page progress for callers. Scripts such as Process-MissingMedarchiv, Evaluate-OrchestraErrorsViaElastic, and Write-ElasticDataToDatabase dot-source this file to keep Elasticsearch pagination logic consistent.

## Documentation references

- **SubflElasticInfo.md** - Overview of Subscription Flow (SUBFL) terminology plus how SUBFL scenarios log to Elasticsearch, including the specific fields and filters leveraged by the SUBFL-related scripts in this repository.
- **ScenarioInfo.md** - Reference for Orchestra scenario folder structure, including expected file naming patterns and scenario-related configuration notes drawn from the scripts.

## Shared date-range behavior

Scripts that expose `StartDate`/`EndDate` now also support `Timespan` as an alternative to `EndDate`. `Timespan` accepts either a number (minutes) or a PowerShell `TimeSpan` value. When `EndDate` and `Timespan` are both omitted, a default window of 15 minutes is used from `StartDate`.
