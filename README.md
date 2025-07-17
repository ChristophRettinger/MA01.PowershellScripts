# MA01 PowerShell Scripts

This repository contains a collection of PowerShell scripts used within the MA01 environment. Each script helps automate a specific operational or analysis task.

## Scripts

- **Add-HostNames.ps1** - Reads a CSV file of IP addresses, resolves host names via DNS, and writes an enriched CSV with the host name added.
- **Analyze-RAG-Metadata.ps1** - Processes RAG usage metadata from a JSON file, computing statistical summaries and field frequency counts.
- **Extract-ChatProperties.ps1** - Extracts selected properties from chat metadata JSON and outputs a simplified JSON file containing only those fields.
- **Host-HttpListener.ps1** - Runs a lightweight HTTP/HTTPS listener that logs request headers and bodies to timestamped files.
- **Test-Connections.ps1** - Tests TCP connectivity to hosts specified in a CSV file, records the result for each host, and updates the file with resolved IP addresses.

