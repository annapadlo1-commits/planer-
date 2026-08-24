# Solver Job dispatcher (UAT)

This Edge Function is the only component allowed to call the Northflank Job
API. The browser can request an explicitly experimental Job generation through
the `request` action, but never receives either the Northflank token or the
per-run solver capability.

Safety defaults live in PostgreSQL: execution mode `SERVICE`, dispatcher
disabled, global concurrency `2`, per-configuration concurrency `1`, and a
12-minute wall timeout. A transport timeout after the Northflank POST becomes
`ACCEPTANCE_UNKNOWN`; it is never automatically POSTed a second time.

