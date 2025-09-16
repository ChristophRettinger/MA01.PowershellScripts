# Contributor Guide

## Documentation
- Update README.md if necessary, even if not asked for
- Always add and maintain documentation at the top of a Powershell script

## Shared Elasticsearch logic
- ❗ Centralize Elasticsearch scroll handling in `Scripts/Common/ElasticSearchHelpers.ps1` using `Invoke-ElasticScrollSearch`. Do **not** duplicate manual paging loops inside individual scripts.
- ❗ Whenever `ElasticSearchHelpers.ps1` changes, review every script that dot-sources it (currently `Evaluate-OrchestraErrorsViaElastic` and `Process-MissingMedarchiv`) and update them to keep behaviour and parameters aligned. Add new scripts to this list when they start using the helper.
