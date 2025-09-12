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
