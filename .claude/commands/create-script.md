Guide the user through creating a new PowerShell script for this repository. Work through four phases in order. Never advance to the next phase without explicit user confirmation.

---

## Phase 1 — Discovery

Your goal is to build a complete, unambiguous understanding of what the script must do before writing a single line of code. Ask the opening question, then follow up until every item in the checklist below is known. Be relentless — do not proceed to Phase 2 until all relevant items are answered.

**Opening question:**
> "What should the new script do? Describe the goal in plain language — inputs, what it does with them, and what output or side-effect you expect."

**After the initial answer, probe any open items from this checklist:**

Input sources
- [ ] Does it read from Elasticsearch? → Which index? Date range? ScenarioName filter? BusinessCaseId/MSGID filter? PatientId filter?
- [ ] Does it read from an Orchestra API (OrchDyn, etc.)? → Which server / environment?
- [ ] Does it read from SQL Server? → Which database? Read-only or does it write?
- [ ] Does it read from local files? → What format? Path as parameter or fixed?
- [ ] Does it call an external HTTP endpoint (REST, SOAP)? → URL in ServerConfig or new?

Parameters
- [ ] Which of the established names apply: `StartDate`/`EndDate`, `ScenarioName`, `OutputDirectory`, `ElasticUrl`, `Environment`, `ResetCredentials`, `BusinessCaseId`/`MSGID`, `PatientId`?
- [ ] Are there numeric parameters that should have a minimum or maximum (e.g., `$MaxRecords`, `$PageSize`)?
- [ ] Are there mutually exclusive parameter combinations?

Output
- [ ] Console report (human-readable text) → needs `Write-ReportLine` pattern + optional `-OutputDirectory`
- [ ] Structured data → needs `Export-Csv` (no `Write-ReportLine`)
- [ ] Side-effect only (database write, file copy, HTTP call) → minimal output, progress messages only
- [ ] Should output be copyable to clipboard?

Authentication / credentials
- [ ] Elasticsearch API key (CLIXML via `Resolve-ElasticCredential`)
- [ ] Orchestra user credentials (CLIXML via `Get-OrchCredential` / `Export-Clixml`)
- [ ] PatAuskunft SOAP credentials
- [ ] SQL Server (Windows auth, no stored credential)
- [ ] None

Error cases
- [ ] What should happen when no results are found? (Write-Warning + return, or just a summary line?)
- [ ] What constitutes a fatal error vs. a skippable warning per item?
- [ ] Are there parameter combinations that are invalid and should `throw` immediately?

Shared helpers
- [ ] Should it dot-source `ElasticSearchHelpers.ps1`? (`Invoke-ElasticScrollSearch`, `Resolve-ElasticCredential`, `Get-ElasticSourceValue`, `Resolve-EffectiveTimespan`)
- [ ] Should it dot-source `ScenarioHelpers.ps1`? (`Get-ScenarioInfo`)
- [ ] Should it dot-source `ServerConfig.ps1`? (`Get-ServerConfig`)
- [ ] Does it need logic that should live in `Scripts/Common/` if it will be reused?

Continue asking until every relevant checkbox above is answered. Summarize your understanding back to the user and ask:
> "Does this capture everything the script needs to do, or is there anything I'm missing?"

Only move to Phase 2 after the user confirms the summary is complete.

---

## Phase 2 — Name suggestion

Based on the confirmed understanding, propose a script name following these rules:
- Must use an approved PowerShell verb (`Get-Verb` list). Common approved verbs: `Get`, `Find`, `Invoke`, `Test`, `New`, `Copy`, `Write`, `Send`, `Show`, `Resolve`, `Start`, `Stop`, `Import`, `Export`, `Compare`, `Set`.
- Never use: `Analyze-`, `Evaluate-`, `Process-`, `Extract-`, `Create-`, `Handle-`, `Call-`, `Transfer-`, `Resend-`, `Validate-`, `Check-`, `Fetch-`, `Build-`, `Load-`, `Log-`, `Parse-`.
- Noun should be specific and PascalCase. Prefer domain terms already used in the repo (e.g., `Orchestra`, `Elastic`, `Scenario`, `Patient`, `Medarchiv`).

Present the suggestion with a one-sentence justification, then ask:
> "Does `Verb-Noun` work as the script name, or would you like a different name?"

Wait for confirmation or an alternative before proceeding.

---

## Phase 3 — Implementation plan

Present a structured plan covering every item below. Do **not** start writing the script yet.

```
Script: Scripts/<Name>/<Name>.ps1

Parameters
  -Param1 [type]  [ValidateRange / ValidateSet / alias if applicable]
  ...

Dot-sourced helpers
  - Scripts/Common/ElasticSearchHelpers.ps1  (if needed)
  - Scripts/Common/ScenarioHelpers.ps1       (if needed)
  - Scripts/Common/ServerConfig.ps1          (if needed)

Functions (defined before SCRIPT BODY separator)
  - FunctionName — purpose

Output approach
  - Write-ReportLine + $script:outputLineBuffer  OR  Export-Csv  OR  progress-only

Credential approach
  - Resolve-ElasticCredential / CLIXML user credential / none

Main body logic
  1. Validate mutually exclusive / dependent parameters (throw on bad input)
  2. Load config / credentials
  3. <core steps in order>
  4. Handle no-results (Write-Warning; return)
  5. Write output file if -OutputDirectory supplied

README entry (draft)
  **<Name>.ps1** — <one-sentence description under 350 characters>
```

After presenting the plan, ask:
> "Does this plan look right? Any changes before I start implementing?"

Only move to Phase 4 after the user explicitly approves.

---

## Phase 4 — Implementation

Implement the script exactly as planned, applying every rule from `review-scripts.md`. The checklist below is your quality gate — verify each item before reporting done.

### Mandatory structure
- [ ] `.SYNOPSIS` / `.DESCRIPTION` / `.PARAMETER` / `.EXAMPLE` doc block at the top
- [ ] `param(...)` block as the first executable element
- [ ] `$ErrorActionPreference = 'Stop'` immediately after `param`
- [ ] `Set-StrictMode -Version Latest` immediately after `param`
- [ ] All dot-sources wrapped in `Test-Path` guard: `if (-not (Test-Path $path)) { throw "Helper not found: $path" }`
- [ ] All functions defined **before** the `SCRIPT BODY` separator
- [ ] `SCRIPT BODY` separator present as a multiline `<# ═══ ... ═══ #>` block

### Error handling
- [ ] No `exit` or `exit 1` — use `throw` for fatal errors, `return` for early exits
- [ ] Invalid parameter combinations → `throw`
- [ ] No-results condition → `Write-Warning "..."; return`
- [ ] `Invoke-RestMethod` / `Invoke-WebRequest` called with `-ErrorAction Stop` or inside `try/catch`

### Parameters
- [ ] Established names used where applicable (`StartDate`, `EndDate`, `ScenarioName`, `OutputDirectory`, `ElasticUrl`, `Environment`, `ResetCredentials`, `BusinessCaseId` with `[Alias('MSGID')]`, `PatientId`)
- [ ] `[ValidateRange(...)]` used instead of manual `if ($x -le 0)` checks
- [ ] No parameter or variable named `$PID`
- [ ] No `$ElasticApiKey` or `$ElasticApiKeyPath` parameters

### Code quality
- [ ] No cmdlet aliases (`%`, `?`, `select`, `where`, `ls`, `dir`, etc.)
- [ ] `Write-Host` not used inside functions that return data
- [ ] Null checks use `$null -eq $x` not `$x -eq $null`
- [ ] Variables inside strings/hashes use `$($var)` when followed by `:`, `.`, `-`, `[`

### Security & credentials
- [ ] No API keys, passwords, or tokens as string literals
- [ ] No `Invoke-Expression` with user-controlled input
- [ ] Elasticsearch API key via `Resolve-ElasticCredential` only
- [ ] No plain-text `.key` files
- [ ] `-ResetCredentials` switch present if script stores credentials
- [ ] Credential file paths derived from `$PSScriptRoot`

### Infrastructure
- [ ] All URLs, server names, and connection strings loaded from `Get-ServerConfig` (not hardcoded)
- [ ] No `targets.csv` or `DatabaseMappings.csv` references

### Output & encoding
- [ ] `Write-Host` calls use `-ForegroundColor` for meaningful output
- [ ] `-OutputDirectory` parameter present for report scripts
- [ ] `Write-ReportLine` + `$script:outputLines` + `$script:outputLineBuffer` pattern used (text output scripts)
- [ ] Buffer flushed before file write
- [ ] `Set-Content` / `Out-File` / `Export-Csv` / `Add-Content` all use `-Encoding UTF8`

### Language
- [ ] All names, comments, and docs in English
- [ ] German Fachbegriffe acceptable where no standard English equivalent exists

### After writing the file
1. Run the syntax check: `pwsh -NoProfile -Command "Get-Command '<absolute-path>' | Out-Null; 'ok'"`
2. If it fails, fix and re-check before continuing.
3. Add the script's entry to `README.md` in alphabetical order under `## Scripts`, using the draft description from Phase 3.
4. Report: file created at `Scripts/<Name>/<Name>.ps1`, syntax ✓, README updated.
