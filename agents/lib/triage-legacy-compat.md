# Legacy Disposition → Triage Mapping

Legacy `disposition:` keys produced before #556 map as follows:

| Legacy `disposition:` | Current `triage:` |
|---|---|
| `fix in scope` | `MUST` |
| `track separately` | `NA` |
| (no OPTIONAL equivalent) | — |

Applies only when reading intent.md from sessions that pre-date #556. New sessions
always emit `triage:`. No runtime converter — readers branch on which key is present.
