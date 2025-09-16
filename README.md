# MA01 PowerShell Scripts

This repository contains a collection of PowerShell scripts used within the MA01 environment. Each script helps automate a specific operational or analysis task.

## Scripts

All scripts are located under the `Scripts` folder, each in its own subfolder named after the script (without the `.ps1` extension).

- **Add-HostNames.ps1** - Reads a CSV file of IP addresses, resolves host names via DNS, and writes an enriched CSV with the host name added.
- **Analyze-RagMetadata.ps1** - Processes RAG usage metadata from a JSON file, computing statistical summaries and field frequency counts.
- **Extract-ChatProperties.ps1** - Extracts selected properties from chat metadata JSON and outputs a simplified JSON file containing only those fields.
- **Start-HttpListener.ps1** - Hosts a lightweight HTTP/HTTPS listener that logs inbound requests to files.
- **Test-Connections.ps1** - Tests TCP connectivity to hosts specified in a CSV file, records the result for each host, and updates the file with resolved IP addresses.
- **Process-MissingMedarchiv.ps1** - Queries changelog data for a date range and compares with Elasticsearch to find missing records. Defaults to today's full day if `StartDate` is omitted. Use `Anstalt` with a specific ID or `All` to process all mappings; results are presented as a single table. Elasticsearch is optional via `-IncludeElastic` and uses `ElasticUrl` + `ElasticApiKey` or `ElasticApiKeyPath`. Also supports `MappingCsvPath`, `ElasticTimeField`, and `IncreaseElasticDateRange` (expands ES time window +/- N hours; default 4). The mapping CSV must include columns `Anstalt,DatabaseName,ElasticName` (example provided under `Scripts/Process-MissingMedarchiv/DatabaseMappings.csv`).
- **Evaluate-OrchestraErrorsViaElastic.ps1** - Retrieves failed Orchestra scenarios from Elasticsearch (with substring matching on `ScenarioName`), groups error messages, optionally writes matching documents to formatted XML files, and normalizes error text via configurable regex replacements that can include optional conditions. Files produced by the `All` and `OneOfType` modes include the timestamp, the original error text, selected business keys, and the message payload embedded as XML nodes (optionally filtered via the `MessagePart` parameter, which keeps `Data` elements whose `@src` attribute starts with the provided value). `All` writes one XML file per occurrence, while `OneOfType` writes only the first occurrence for each normalized error. File names combine the run date, a sequential counter, and the first 20 characters of the normalized error. The `Environment` parameter defaults to `production`. Note: The script posts JSON with the correct `Content-Type` header; if you previously saw a 406 "Content-Type header [application/x-www-form-urlencoded] is not supported", update to the current version.

## Shared utilities

- **Scripts/Common/ElasticSearchHelpers.ps1** - Hosts `Invoke-ElasticScrollSearch`, a reusable helper that issues scroll queries, aggregates all hits, surfaces detailed error information, and optionally reports page progress for callers. Scripts such as Process-MissingMedarchiv and Evaluate-OrchestraErrorsViaElastic dot-source this file to keep Elasticsearch pagination logic consistent.
