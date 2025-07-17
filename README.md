# MA01 PowerShell Scripts

This repository contains a collection of PowerShell scripts used within the MA01 environment. Each script helps automate a specific operational or analysis task.

## Scripts

All scripts are located under the `Scripts` folder, each in its own subfolder named after the script (without the `.ps1` extension).

- **Add-HostNames.ps1** - Reads a CSV file of IP addresses, resolves host names via DNS, and writes an enriched CSV with the host name added.
- **Analyze-RagMetadata.ps1** - Processes RAG usage metadata from a JSON file, computing statistical summaries and field frequency counts.
- **Extract-ChatProperties.ps1** - Extracts selected properties from chat metadata JSON and outputs a simplified JSON file containing only those fields.
- **Start-HttpListener.ps1** - Hosts a lightweight HTTP/HTTPS listener that logs inbound requests to files.
- **Test-Connections.ps1** - Tests TCP connectivity to hosts specified in a CSV file, records the result for each host, and updates the file with resolved IP addresses.
