# Errors

Most commands return non-zero exit codes on failure and may emit a structured error envelope.

## The final line: `br: FAILED (CODE, exit N)`

Every nonzero exit ends with **one** self-identifying line on stderr, and it is
the **last** thing written:

```console
$ br create "" --prefix ct --json 2>&1 | tail -1
br: FAILED (VALIDATION_FAILED, exit 4)
```

Why last, and why this matters: `br`'s stream routing was always correct — a
failing command writes nothing to stdout and the whole envelope to stderr — so
piping alone hid nothing. What hid failures was `2>&1` **plus** a truncating
filter. Every discriminating token in the envelope (`"error"`, the code, the
message) is at the *top*, and `tail` shows the *bottom*, so what survived was
closing braces — which is also how a *success* envelope ends. A banner printed
first would be the first thing cut off; this one is positioned to be the thing
that survives.

Properties you can rely on:

- **Unconditional on nonzero exit.** Not gated on being a terminal or on being
  piped, so it behaves identically by hand and in a script.
- **Last.** stdout is flushed immediately before it is written, so it does not
  lose the position to a buffered partial line under `2>&1`.
- **One line, no ANSI, on stderr.** `grep` matches it; `tail -1` shows all of
  it; a `--json` consumer reading stdout is byte-for-byte unaffected.
- **It never claims a failure that did not happen.** A nonzero exit that is a
  *result* rather than an error reads `br: UPDATE_AVAILABLE (exit 1)` — no
  `FAILED`. It matches the `"error"`/`"notice"` split of the envelopes below.
- The name is whatever you invoked (`bd` through the symlink, `br` otherwise).

Not covered, because no user code runs: death by signal (`SIGKILL`,
`SIGTERM`). A fatal panic *is* covered.

### This does NOT fix the exit code — and that is the half that bites hardest

The banner hardens the **text** channel only. `$?` after a pipeline is the
*last* command's status by shell semantics, so this still reports success:

```bash
br create "" --prefix ct | tail -3   # $? is tail's 0, and always will be
```

No change to `br` can alter that. If you care about the status of a piped
`br`, you must ask for it:

```bash
set -o pipefail                       # then $? is br's 4
br ... | tail -3
# or
br ... > out.txt; status=$?           # don't pipe what you need the status of
# or
br ... | tail -3; status=${PIPESTATUS[0]}   # bash
```

Seeing `br: FAILED (...)` in a log is *not* evidence that the surrounding
script noticed.

Example (captured with stderr redirection):

```bash
br show bd-NOTEXIST --format json > /dev/null 2>err.json || true
cat err.json | jq .
```

Shape:

```json
{
  "error": {
    "code": "ISSUE_NOT_FOUND",
    "message": "Issue not found: bd-NOTEXIST",
    "hint": "Run 'br list' to see available issues.",
    "retryable": false,
    "context": { "searched_id": "bd-NOTEXIST" }
  }
}
```

Machine-readable schema:

```bash
br schema error --format json
```

## `br close`: what the exit code means

`br close` answers "is the world in the state you asked for?", not "did br
perform a write". Check the exit code, and read `context.skipped[]` — never
the prose — to find out why an id did not close.

| Outcome | Code | Exit |
| --- | --- | --- |
| every requested id closed | (no envelope) | 0 |
| some ids were already closed, nothing outstanding | `ALREADY_SATISFIED` (a `notice`, not an `error`) | 0 |
| nothing closed, something outstanding | `NOTHING_TO_DO` | 3 |
| some closed, something outstanding | `PARTIALLY_CLOSED` | 3 |

Re-closing an already-closed issue succeeds (as `mkdir -p` does), so a retry
loop is safe. The skip is still reported: a success that skipped something
prints a `notice` envelope on stderr with the same `context` an error would
carry.

`br close A B C` applies per id: the ids that can close do close, and the
exit code is non-zero if any requested id did not reach the closed state.
(Blocked-ness is recomputed as the batch proceeds, so `br close <blocker>
<blocked>` closes both.) Never treat a `PARTIALLY_CLOSED` exit as "nothing
happened" — read `context.closed_count` and `context.outstanding`.

Each entry of `context.skipped[]` carries:

- `reason` — a stable discriminator: `blocked`, `already_closed`,
  `tombstoned`, `not_found`. Key on this.
- `blockers` — for `blocked`, the blocking ids (as `id:status`).
- `end_state_reached` — whether that id is nonetheless in the state you
  asked for (`true` only for `already_closed`).
- `detail` — the same sentence as the human `Warning: Skipped ...` line.

`context.outstanding` is the subset you still have to act on.

```json
{
  "error": {
    "code": "PARTIALLY_CLOSED",
    "message": "Closed 1 of 2 requested issue(s): 1 skipped",
    "hint": "1 of 2 requested issue(s) closed. bd-blocked was not closed: blocked by: bd-blocker:open. Close the blocker(s) first ('br close bd-blocker'), or re-run with --force to close bd-blocked anyway.",
    "retryable": false,
    "context": {
      "reason": "closed 1 of 2, 1 skipped",
      "requested_count": 2,
      "closed_count": 1,
      "skipped_count": 1,
      "skip_reasons": ["blocked"],
      "outstanding": ["bd-blocked"],
      "skipped": [
        {
          "id": "bd-blocked",
          "reason": "blocked",
          "detail": "blocked by: bd-blocker:open",
          "end_state_reached": false,
          "blockers": ["bd-blocker:open"]
        }
      ]
    }
  }
}
```

The exit-0-with-a-skip case uses the same shape under a `notice` key, so a
caller that looks for `"error"` is never told about a failure that did not
happen:

```json
{
  "notice": {
    "code": "ALREADY_SATISFIED",
    "message": "1 issue(s) are closed as requested; 1 needed no change",
    "hint": "bd-done: already closed. Nothing changed. Use 'br reopen bd-done' if the work is not actually done.",
    "context": {
      "reason": "closed 0 of 1, 1 already in the requested state",
      "requested_count": 1,
      "closed_count": 0,
      "skipped_count": 1,
      "skip_reasons": ["already_closed"],
      "outstanding": [],
      "skipped": [
        {
          "id": "bd-done",
          "reason": "already_closed",
          "detail": "already closed",
          "end_state_reached": true
        }
      ]
    }
  }
}
```
