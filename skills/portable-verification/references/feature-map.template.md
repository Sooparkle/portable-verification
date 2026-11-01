# Feature map

One section per user-facing feature. Start with the 3-5 features users depend on most.
Planted as .verification/feature-map.md; fill it in per project.

## <feature-name>
- User entry path: <where a user starts, e.g. /login page, `mycli init`>
- Launch: <command> | ready signal: <log line or port> | stop: <how to stop only what you started>
- Doctor (read-only health check): <command>
- Drive (Tier B): <Playwright spec, curl sequence, or CLI steps>
- Side effects to check: <DB row, file, outbound call>
- Fast check (Tier A candidate): <focused test command>
- Required check ids in checks.txt: <ids>
- Reversibility: two-way door | one-way door (why)
- Gotchas: <ports, seed data, auth, flaky steps>
