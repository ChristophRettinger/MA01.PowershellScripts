# Contributor Guide

## Documentation
- Update README.md if necessary, even if not asked for
- Keep README.md script descriptions concise and consistent; avoid default values, color mentions, or overly detailed parameter listings.
- Always add and maintain documentation at the top of a Powershell script
- Keep SUBFL Elasticsearch context current in `SubflElasticInfo.md` when related scripts or knowledge change
- Update `ScenarioInfo.md` when scripts or knowledge change

## Shared Elasticsearch logic
- Centralize Elasticsearch scroll handling in `Scripts/Common/ElasticSearchHelpers.ps1` using `Invoke-ElasticScrollSearch`. Do **not** duplicate manual paging loops inside individual scripts.
- Whenever `ElasticSearchHelpers.ps1` changes, review every script that dot-sources it (currently `Evaluate-OrchestraErrorsViaElastic` and `Process-MissingMedarchiv`) and update them to keep behaviour and parameters aligned. Add new scripts to this list when they start using the helper.
- When filtering for ScenarioName do not use "ScenarioName.keyword", just plain "ScenarioName"
- Use MSGID as shorthand for BusinessCaseId 
- Never define script parameters or local variables named `PID`; PowerShell reserves `$PID` as a read-only automatic variable. Use `PatientId` for script parameters and internal variables instead.

## PowerShell Variable Interpolation

- Do not place a colon or other special characters directly after a variable (e.g., "$x: 1"). This is invalid PowerShell syntax.
  When a variable is followed immediately by characters like :, ., -, [, etc., always wrap the variable using sub-expression syntax:
  $($x): 1
  This applies especially inside hash literals and interpolated strings. Always use $($var) when the parser would otherwise misinterpret the variable boundary.

## Basic script validation

- Always run a basic PowerShell command check after script updates to catch syntax issues early, for example:
  `pwsh -NoProfile -Command "Get-Command ./Scripts/Resend-FromElastic/Resend-FromElastic.ps1 | Out-Null; 'ok'"`
  
