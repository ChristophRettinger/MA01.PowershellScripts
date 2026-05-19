Review the PowerShell scripts in this repository and report issues by severity.

## Determining scope from $ARGUMENTS

- No arguments → review only `.ps1` files that differ from `main` (`git diff --name-only main HEAD -- "*.ps1"`). If the branch IS main, compare to the previous commit (`git diff --name-only HEAD~1 HEAD -- "*.ps1"`).
- `--all` → review every `.ps1` under `Scripts/` recursively.
- Any other argument → treat it as a path or glob pattern and review the matching script(s).

If no scripts fall into the determined scope, say so and stop.

Before reviewing individual scripts, load the following context files once:
- `README.md` — for description length and consistency checks
- `Scripts/Common/ElasticSearchHelpers.ps1` — to know what helpers already exist
- `Scripts/Common/ScenarioHelpers.ps1` — to know what scenario helpers exist
- `Scripts/Common/ServerConfig.psd1` — to know what servers, URLs, and connection strings are centrally defined

---

## Per-script review process

Work through each script in scope. For every script:

### Step 1 — Syntax validation
Run: `pwsh -NoProfile -Command "Get-Command '<absolute-path>' | Out-Null; 'ok'"`
- `ok` → syntax passes.
- Error → report **[CRITICAL] Syntax error** with the error message.

### Step 2 — Read the script
Read the full file. All subsequent checks are based on this content.

### Step 3 — Script structure

Functions must all appear before the main script body. The transition from functions to body must be marked with a recognizable multiline comment block:

```powershell
<#
═══════════════════════════════════════════════════════════
  SCRIPT BODY
═══════════════════════════════════════════════════════════
#>
```

| ID | What to check | Severity |
|----|---------------|----------|
| ST1 | A function is defined **after** the main script body has already started (i.e. executable statements appear before a `function` keyword) | WARN |
| ST2 | The script has functions but no separator comment marking where the body begins | INFO |
| ST3 | The separator exists but is a single-line `#` comment rather than a multiline block — makes it hard to spot when scrolling | INFO |

### Step 4 — Script-level setup

| ID | What to check | Severity |
|----|---------------|----------|
| SET1 | `$ErrorActionPreference = 'Stop'` not set immediately after the `param` block | WARN |
| SET2 | `Set-StrictMode -Version Latest` not set immediately after the `param` block | WARN |
| SET3 | Script dot-sources a shared helper without a `Test-Path` guard — e.g. `. $path` without first checking `if (-not (Test-Path $path)) { throw }` | WARN |

### Step 5 — Error handling

| ID | What to check | Severity |
|----|---------------|----------|
| EH1 | `exit` or `exit 1` used anywhere in the script. `exit` terminates the entire PowerShell host — unsafe when dot-sourced, run from an IDE, or called in a pipeline. Use `throw` for fatal errors, `return` for early exits | WARN |
| EH2 | A no-results / nothing-found condition is signaled with `throw` or `Write-Error` instead of `Write-Warning "..."; return` | INFO |
| EH3 | Script signals invalid user input (bad parameter value, conflicting options) with `Write-Error; return` instead of `throw`. Bad input is a programmer/user error — use `throw` | INFO |
| EH4 | `Invoke-RestMethod` or `Invoke-WebRequest` called without `-ErrorAction Stop` and outside a `try/catch` | WARN |

### Step 6 — Parameter design

Key established parameter names to enforce for PM3:
- `StartDate` / `EndDate` — date range inputs
- `ScenarioName` — Orchestra scenario filter
- `OutputDirectory` — file output path
- `ElasticUrl` — Elasticsearch base URL
- `Environment` — deployment environment (`production`, `staging`, `testing`, `development`)
- `ResetCredentials` — force credential re-prompt
- `BusinessCaseId` with alias `MSGID` — message/case identifier
- `PatientId` (never `$PID`)

| ID | What to check | Severity |
|----|---------------|----------|
| PM1 | Function uses a non-approved verb (anything not in `Get-Verb` output). Common offenders: `Check-`, `Fetch-`, `Build-`, `Load-`, `Log-`, `Parse-` | WARN |
| PM2 | Script file name uses a non-approved verb as its `Verb-` prefix. Common offenders: `Analyze-`, `Evaluate-`, `Process-`, `Extract-`, `Create-`, `Handle-`, `Call-`, `Transfer-`, `Resend-`, `Validate-` | WARN |
| PM3 | Script uses a different name for a parameter with the same semantic meaning as an established name above (e.g. `$DateFrom` instead of `$StartDate`) | WARN |
| PM4 | Script uses `BusinessCaseId` but does not define the `MSGID` alias (or vice versa) | INFO |
| PM5 | An alias is defined in one script for a parameter but the equivalent parameter in a sibling script lacks the same alias | INFO |
| PM6 | Manual numeric range check in the script body (e.g. `if ($x -le 0) { ... }`) that could be replaced with a `[ValidateRange(...)]` attribute on the parameter declaration | INFO |

### Step 7 — Code idioms

| ID | What to check | Severity |
|----|---------------|----------|
| QA1 | Aliases used inside the script body: `ls`, `dir`, `%`, `?`, `select`, `where`, `ft`, `fl`, `gci`, `gc`, `ni`, `rm`, `cp`, `mv`, `cat`, `echo` | INFO |
| QA2 | `Write-Host` used inside a function that is supposed to return data (functions should use `Write-Output` or simply return; `Write-Host` in top-level script flow is fine) | INFO |
| QA3 | `$null -eq` check written the wrong way around (`$x -eq $null`) — arrays can cause false results | INFO |

### Step 8 — Security

| ID | What to check | Severity |
|----|---------------|----------|
| SEC1 | API key, password, or token hardcoded as a string literal (patterns: `ApiKey = "..."`, `Bearer ...`, `Password = "..."`, `-Token "..."`) | CRITICAL |
| SEC2 | `Invoke-Expression` called with a variable or concatenated string that could include user input | CRITICAL |
| SEC3 | Sensitive values (API keys, tokens, passwords) written to `Write-Host`, `Write-Output`, or log files | WARN |
| SEC4 | Plain `http://` (not `https://`) used for external service URLs | WARN |
| SEC5 | Credential or secret files adjacent to the script that are **not** listed in `.gitignore` (e.g. `*.clixml`, `*.key`) | WARN |

### Step 9 — Credential storage

There are two canonical patterns, both using CLIXML (DPAPI-encrypted, user+machine bound):

**User credentials** (username + password): `Get-Credential` → `Export-Clixml` to `$PSScriptRoot\<server>.credentials.clixml`. On reload: `Import-Clixml`. Reference: `Get-DeploymentInfo.ps1` (`Get-OrchCredential`) and `Invoke-PatAuskunft.ps1`.

**API keys** (single opaque string): call `Resolve-ElasticCredential` from `Scripts/Common/ElasticSearchHelpers.ps1`, passing `$PSScriptRoot\elastic.credentials.clixml` as `-CredentialPath`. The API key is stored as the password field of a PSCredential and extracted with `.GetNetworkCredential().Password`. Reference: all Elasticsearch scripts.

Neither pattern uses plain-text `.key` files or string parameters that expose secrets in shell history.

| ID | What to check | Severity |
|----|---------------|----------|
| CR1 | Script uses an Elasticsearch API key but calls `Resolve-ElasticCredential` from somewhere other than `Scripts/Common/ElasticSearchHelpers.ps1`, or implements its own key-file / string-parameter pattern | WARN |
| CR2 | Script still has `$ElasticApiKey` or `$ElasticApiKeyPath` parameters (old pattern) | CRITICAL |
| CR3 | Script still reads an `elastic.key` plain-text file | CRITICAL |
| CR4 | Script uses credentials but has no `-ResetCredentials` switch | INFO |
| CR5 | Credential or key file path is hardcoded to an absolute path instead of being derived from `$PSScriptRoot` | WARN |
| CR6 | Script uses `Get-Credential` / `Export-Clixml` for user credentials but the credential file is not covered by `.gitignore` (`*.clixml` or `*.credentials.clixml`) | WARN |

### Step 10 — Infrastructure

All service URLs, server names, connection strings, and environment-to-URL mappings must be defined in `Scripts/Common/ServerConfig.psd1` and loaded via `Get-ServerConfig` from `Scripts/Common/ServerConfig.ps1`. No script body (including parameter defaults) may embed these as string literals.

| ID | What to check | Severity |
|----|---------------|----------|
| U1 | Service URL, server name, connection string, or environment-to-URL mapping hardcoded as a string literal anywhere in the script — including parameter defaults — instead of being read from `Get-ServerConfig` | WARN |
| U2 | Server hostname or environment-to-URL mapping table defined inside the script body when the same value exists in `ServerConfig.psd1` | WARN |
| U3 | `targets.csv` or `DatabaseMappings.csv` still referenced directly — both are superseded by `ServerConfig.psd1` (`OrchestraTargets` and `MedarchivDatabases`) | WARN |

### Step 11 — Output & I/O

**Canonical text output pattern** — use `Write-ReportLine` with a `$script:outputLineBuffer` for `-NoNewline` support:

```powershell
$script:outputLines      = [System.Collections.Generic.List[string]]::new()
$script:outputLineBuffer = ''

function Write-ReportLine {
    param([string]$Text = '', [string]$Color = 'White', [switch]$NoNewline)
    Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewline
    $script:outputLineBuffer += $Text
    if (-not $NoNewline) {
        [void]$script:outputLines.Add($script:outputLineBuffer)
        $script:outputLineBuffer = ''
    }
}
```

At the end of the script, flush any unflushed buffer and write the file:

```powershell
if ($script:outputLineBuffer) { [void]$script:outputLines.Add($script:outputLineBuffer); $script:outputLineBuffer = '' }
if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $stamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
    $filePath = Join-Path $OutputDirectory "ScriptName_$stamp.txt"
    $script:outputLines | Set-Content -Path $filePath -Encoding UTF8
    Write-Host "Report written to '$filePath'" -ForegroundColor Cyan
}
```

Scripts that produce structured tabular data use `Export-Csv -NoTypeInformation -Encoding UTF8` instead and do **not** need `Write-ReportLine`. All file I/O must use UTF-8 encoding.

| ID | What to check | Severity |
|----|---------------|----------|
| OUT1 | Script produces meaningful output but makes no use of `-ForegroundColor` on any `Write-Host` call | WARN |
| OUT2 | Script has no `-OutputDirectory` parameter (or equivalent) for writing output to a file | INFO |
| OUT3 | Script has `-OutputDirectory` but does not write a file when the parameter is supplied (i.e. the parameter exists but is unused/ignored) | WARN |
| OUT4 | Script has `-OutputDirectory` and produces human-readable text output but uses bare `Write-Host`, a `StringBuilder`, or a plain list instead of the `Write-ReportLine` / `$script:outputLineBuffer` pattern | WARN |
| OUT5 | Script defines `Write-ReportLine` but does not declare `$script:outputLineBuffer` — partial-color lines via `-NoNewline` will silently drop content from the file | WARN |
| OUT6 | `Set-Content` without `-Encoding UTF8` | WARN |
| OUT7 | `Out-File` without `-Encoding UTF8` | WARN |
| OUT8 | `Export-Csv` without `-Encoding UTF8` | WARN |
| OUT9 | `Add-Content` without `-Encoding UTF8` | WARN |
| OUT10 | `Get-Content` without `-Encoding UTF8` when reading files that are expected to be UTF-8 (script-produced files, config files) | INFO |
| OUT11 | Script writes a file to a path derived from `$OutputDirectory` but never calls `New-Item -ItemType Directory -Force` (or `[IO.Directory]::CreateDirectory`) before the write — fails if the directory does not exist | WARN |

### Step 12 — Project conventions

| ID | What to check | Severity |
|----|---------------|----------|
| IC1 | Variable directly followed by `:`, `.`, `-`, `[` inside a string or hash literal **without** `$()` wrapping — e.g. `"$x: 1"` instead of `"$($x): 1"` | WARN |
| IC2 | `$PID` used as a script parameter name or local variable | CRITICAL |
| IC3 | Manual Elasticsearch paging loop (a `while`/`do-while` that fetches `_scroll_id` or increments `$from`/`$page`) instead of calling `Invoke-ElasticScrollSearch` | WARN |
| IC4 | `ScenarioName.keyword` used in an Elasticsearch query body | WARN |
| IC5 | Script dot-sources `ElasticSearchHelpers.ps1` but still contains its own paging loop | WARN |

### Step 13 — Shared code

Non-trivial logic used by more than one script should live in `Scripts/Common/`, not be duplicated inline.

| ID | What to check | Severity |
|----|---------------|----------|
| SC1 | Script contains a helper function that is substantially identical to one in another reviewed script or in `Common/` | WARN |
| SC2 | Script contains non-trivial logic (>15 lines) that is duplicated in at least one sibling script and is not in `Common/` | WARN |

### Step 14 — Documentation

| ID | What to check | Severity |
|----|---------------|----------|
| DOC1 | Missing `<# .SYNOPSIS` documentation block at the top of the script | WARN |
| DOC2 | README description for this script exceeds 350 characters | WARN |
| DOC3 | Script exists but has no entry in README.md | WARN |

### Step 15 — Language consistency

Code (parameter names, variable names, function names, inline comments, documentation) must be English. German "Fachbegriffe" — domain-specific terms with no standard English equivalent in this context — are acceptable (e.g. `Kostenstelle`, `Anstalt`, `LEISTKST`, `Fachrichtung`, `Bewegung`, `CASENO`).

| ID | What to check | Severity |
|----|---------------|----------|
| L1 | Parameter or variable name is an ordinary German word that has a clear English equivalent (e.g. `$Anzahl` instead of `$Count`, `$Ergebnis` instead of `$Result`) | WARN |
| L2 | Inline code comment written in German where a Fachbegriff is not involved | INFO |
| L3 | Documentation block (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`) written in German | WARN |

---

## Output format

Print findings grouped by script. Use this exact structure:

```
════════════════════════════════════════════════
 Scripts/ScriptName/ScriptName.ps1
════════════════════════════════════════════════
[CRITICAL] (SEC1) Line 42  — API key hardcoded: $ApiKey = "abc123..."
[WARN]     (DOC1) Line 1   — Missing <# .SYNOPSIS #> documentation block
[WARN]     (EH4)  Line 88  — Invoke-RestMethod called without -ErrorAction Stop outside try/catch
[INFO]     (QA1)  Line 34  — Alias 'select' used; prefer 'Select-Object'

✓ Syntax check passed
```

If a script has no findings:
```
════════════════════════════════════════════════
 Scripts/ScriptName/ScriptName.ps1
════════════════════════════════════════════════
No issues found. ✓ Syntax check passed
```

After all scripts, print a summary:

```
═══════════════════════════════
 Review summary — N script(s)
═══════════════════════════════
Scripts with issues : X / N
  CRITICAL          : N
  WARN              : N
  INFO              : N
```

---

## After the report

Once the full report is printed, ask:

> "Would you like me to fix any of these issues? I can work through them script by script, showing you the exact change before applying it."

If the user says yes (or names specific scripts/issues):
1. State exactly what you will change and why.
2. Apply the edit.
3. Re-run the syntax check to confirm nothing broke.
4. Move to the next issue.

Do **not** fix issues silently or in bulk without confirmation.
