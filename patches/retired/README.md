# Retired source patches

## 0011-combo-gate-accept-sse-comments.patch — superseded by upstream v3.8.50

Fixed upstream. `open-sse/services/combo/validateQuality.ts` now reads:

    if (trimmed.startsWith("data:") || trimmed.startsWith("event:") || trimmed.startsWith(":"))

with a comment describing the same keep-alive case our patch was written for
(`nara` sends ": ka", `freetheai` sends ": freetheai keepalive").

Upstream trims once and tests for a leading ":". Our patch was slightly stricter —
it skipped *repeated* blank/comment lines and then required a real SSE field
(`data|event|id|retry`), bounded to 50 lines. Upstream's version covers every case
observed on this deploy. Re-apply ours only if a provider is seen sending several
comment lines before its first frame, which would still satisfy upstream's check
anyway (the first trimmed char is still ":").

Verified redundant against v3.8.50 on 2026-08-27: `git apply --check` fails because
the target line already carries the fix, not because of drift.
