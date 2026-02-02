# MA01 PowerShell Scripts

This repository contains a collection of PowerShell scripts used within the MA01 environment. Each script helps automate a specific operational or analysis task.

## Scripts

All scripts are located under the `Scripts` folder, each in its own subfolder named after the script (without the `.ps1` extension).

- **Add-HostNames.ps1** - Resolves IP addresses from a CSV file to host names and writes the enriched CSV.
- **Analyze-RagMetadata.ps1** - Summarizes RAG usage metadata from JSON and reports statistics plus field frequencies.
- **Extract-ChatProperties.ps1** - Selects specific chat metadata fields and outputs a simplified JSON file.
- **Start-HttpListener.ps1** - Runs a lightweight HTTP/HTTPS listener that logs inbound requests.
- **Test-Connections.ps1** - Checks TCP connectivity for CSV-listed hosts and records results with resolved IPs.
- **Process-MissingADM.ps1** - Compares ADM changelog IDs with Elasticsearch results and outputs missing IDs.
- **Process-MissingMedarchiv.ps1** - Compares changelog data with Elasticsearch to find missing Medarchiv records.
- **Evaluate-OrchestraErrorsViaElastic.ps1** - Aggregates failed Orchestra scenarios from Elasticsearch and optionally exports normalized error XML.
- **Evaluate-AdmKavideErrors.ps1** - Collects and summarizes Kavide scenario errors from Elasticsearch with per-case details.
- **Get-PatientInfo.ps1** - Retrieves SUBFL HCM messages for a patient or case and exports structured JSON.
- **Validate-Scenarios.ps1** - Validates scenario configuration files or PSC archives, with optional validation-category filtering, wildcard filtering that matches folder names or PSC base names, and optional text report output (ignores non-XML PSC entries).
- **Transfer-OperationData.ps1** - Transfers DataStore rows into OrchestraOperationData using resumable batches.

## Shared utilities

- **Scripts/Common/ElasticSearchHelpers.ps1** - Hosts `Invoke-ElasticScrollSearch`, a reusable helper that issues scroll queries, aggregates all hits, surfaces detailed error information, and optionally reports page progress for callers. Scripts such as Process-MissingMedarchiv and Evaluate-OrchestraErrorsViaElastic dot-source this file to keep Elasticsearch pagination logic consistent.

## Documentation references

- **SubflElasticInfo.md** - Overview of Subscription Flow (SUBFL) terminology plus how SUBFL scenarios log to Elasticsearch, including the specific fields and filters leveraged by the SUBFL-related scripts in this repository.
- **ScenarioInfo.md** - Reference for Orchestra scenario folder structure, including expected file naming patterns and scenario-related configuration notes drawn from the scripts.
