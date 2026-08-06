# CI gate and branch protection for `main`

Before this change, `.github/workflows/` was empty and
`gh api repos/mindreader/beads_rust/branches/main/protection` returned 404 —
there was no automated gate of any kind on this fork, and PRs merged on human
review alone. `.github/workflows/ci.yml` adds one; this document is the exact
`gh api` recipe to make its checks *required*, plus the reasoning a reviewer
would otherwise have to reconstruct.

**GitHub Actions was in `major_outage` at the time this was written.** Nothing
below has an actual green Actions run behind it. What follows distinguishes,
explicitly, what was proved by running the equivalent commands locally
(same nightly toolchain the workflow installs, via `devenv shell`) from what
is argued from reading the workflow and the tools that validated its shape.
See "Verification" below before trusting any of this on the strength of a
badge.

## What the workflow checks, and the exact required-check names

`.github/workflows/ci.yml` triggers on `pull_request` targeting `main` (a
`push`-only trigger would run after a PR merges — too late to gate anything)
plus `workflow_dispatch` for manual re-runs. Workflow-level `permissions:` is
`contents: read`; nothing in it needs to write.

| Job (exact check name as it will appear on the PR) | Command | Required now? |
|---|---|---|
| `fmt` | `cargo fmt --all -- --check` | **No** — see "The fmt exception" below |
| `clippy (all-features)` | `cargo clippy --locked --all-targets --all-features -- -D warnings` | Yes |
| `clippy (no-default-features)` | `cargo clippy --locked --all-targets --no-default-features -- -D warnings` | Yes |
| `build` | `cargo build --locked --all-targets --all-features` | Yes |
| `test (shard 1/4, all-features)` … `test (shard 4/4, all-features)` | sharded `cargo test --locked --all-features --test <name>` | Yes |
| `test (shard 1/4, no-default-features)` … `test (shard 4/4, no-default-features)` | same, `--no-default-features` | Yes |
| `test (lib + doctests, all-features)` | `cargo test --locked --all-features --lib` then `--doc` | Yes |
| `test (lib + doctests, no-default-features)` | same, `--no-default-features` | Yes |

Rule applied to every row in the "required now" column, per the project
leader's ruling: **a check is eligible for the required list only if it was
actually measured green on `main`, not argued to be green.** Every "Yes" row
above was run locally against this branch's tree before this PR touched any
`.rs` file (i.e. against a tree identical to `main` for compilation
purposes) — see "Verification" for the actual commands and exit codes. If a
future promotion of a currently-unrequired check turns out red on `main`
when someone goes to flip it, do not add it to the required list anyway;
follow the same three-step pattern as the fmt exception below.

### The fmt exception, and the exact three-step follow-up

`cargo fmt --all -- --check` **fails on `main` right now** — a pre-existing,
unrelated formatting backlog across (at least) `tests/common/cli.rs` and
`tests/storage_list_filters.rs`, corroborated by `scripts/ci-local.sh`'s own
comment ("The `cargo fmt --all -- --check` step FAILS on a long-standing
backlog of unformatted files"). Measured directly: `cargo fmt --all --
--check` on this tree exits `1` with ~2854 lines of diff.

The `fmt` job in `ci.yml` runs this check for real — no `continue-on-error`,
no suppression — so it is genuinely red on this very PR. It is **not** in
the required-checks list yet, and that is not an oversight:

> A required check that is red on `main` is a merge deadlock. If `fmt` were
> required today, the only PR that could turn it green — the one that
> formats the tree — could not merge either, because it is itself a PR and
> the check runs on it. Bypassing branch protection once to land that PR
> teaches everyone it's bypassable.

The follow-up, in order:

1. **(this PR)** Land the gate with `fmt` present and running for real, but
   not in the required-checks list.
2. **(separate PR, next)** A purely mechanical `cargo fmt --all` commit —
   nothing else in it, so it's trivially reviewable and doesn't fight with
   any other in-flight branch. Once merged, `fmt` is green on `main`.
3. **(after step 2 is merged and green)** Run the "add fmt" `gh api` call
   below to fold `fmt` into the required list.

## The `gh api` invocations

These configure branch protection on `main`. Whoever runs them needs admin
rights on `mindreader/beads_rust`; expect a `403` otherwise, and do not
silently skip it — flag it back to the fork owner.

### Step A (this PR): required checks, without `fmt`

```bash
gh api --method PUT repos/mindreader/beads_rust/branches/main/protection \
  -H "Accept: application/vnd.github+json" \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "checks": [
      { "context": "clippy (all-features)" },
      { "context": "clippy (no-default-features)" },
      { "context": "build" },
      { "context": "test (shard 1/4, all-features)" },
      { "context": "test (shard 2/4, all-features)" },
      { "context": "test (shard 3/4, all-features)" },
      { "context": "test (shard 4/4, all-features)" },
      { "context": "test (shard 1/4, no-default-features)" },
      { "context": "test (shard 2/4, no-default-features)" },
      { "context": "test (shard 3/4, no-default-features)" },
      { "context": "test (shard 4/4, no-default-features)" },
      { "context": "test (lib + doctests, all-features)" },
      { "context": "test (lib + doctests, no-default-features)" }
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON
```

`strict: true` means a PR branch must be up to date with `main` before these
checks are considered satisfied (re-runs on rebase/merge commit, not just on
the PR's original head) — appropriate here since a stale branch could be
missing a fix that made these checks pass. `enforce_admins: true` means
admins are held to the same gate; drop it (set `false`) if that's not
wanted, but note that's the exact bypass hazard the fmt exception above is
about avoiding. `required_pull_request_reviews` and `restrictions` are left
`null` (no review-count requirement, no push restrictions) since this PR's
mandate is the status-check gate, not a review policy; add those separately
if wanted.

### Step B (after the mechanical fmt commit lands and is green): add `fmt`

```bash
gh api --method PUT repos/mindreader/beads_rust/branches/main/protection/required_status_checks \
  -H "Accept: application/vnd.github+json" \
  --input - <<'JSON'
{
  "strict": true,
  "checks": [
    { "context": "fmt" },
    { "context": "clippy (all-features)" },
    { "context": "clippy (no-default-features)" },
    { "context": "build" },
    { "context": "test (shard 1/4, all-features)" },
    { "context": "test (shard 2/4, all-features)" },
    { "context": "test (shard 3/4, all-features)" },
    { "context": "test (shard 4/4, all-features)" },
    { "context": "test (shard 1/4, no-default-features)" },
    { "context": "test (shard 2/4, no-default-features)" },
    { "context": "test (shard 3/4, no-default-features)" },
    { "context": "test (shard 4/4, no-default-features)" },
    { "context": "test (lib + doctests, all-features)" },
    { "context": "test (lib + doctests, no-default-features)" }
  ]
}
JSON
```

Each `{ "context": ... }` entry omits `app_id`, which GitHub treats as
"match this context name regardless of which App reported it" (the modern,
non-deprecated equivalent of the old flat `contexts` array). If you want to
pin these specifically to the GitHub Actions app rather than any reporter of
a same-named status, look up its app id with
`gh api repos/mindreader/beads_rust/commits/main/check-runs` (once a run has
landed) and add `"app_id": <id>` to each entry.

### Verifying protection took effect

```bash
gh api repos/mindreader/beads_rust/branches/main/protection
```

Before this PR that 404s. After Step A it should return the
`required_status_checks` object with 13 contexts; after Step B, 14.

## Toolchain decision: rustup + `rust-toolchain.toml`, not devenv, in CI

`devenv.nix` provisions the compiler via `fenix.latest` (a *floating*
reference that in practice resolves against the pinned `devenv.lock`,
currently nightly 2026-05-11 / rustc 1.97.0-nightly), plus
`pkg-config`/`openssl`/`sqlite`/`gcc` as system packages, and prints a long
comment warning that bumping `devenv.lock` silently changes the lint set.

CI does **not** reproduce devenv. Instead:

- `rust-toolchain.toml` already pins `channel = "nightly"` with the
  `rustfmt`/`clippy` components this repo needs. GitHub's `ubuntu-latest`
  runners ship `rustup`, which auto-installs whatever toolchain (and
  components) that file names the first time it's invoked in the checkout
  — `rustup show` is enough to trigger it. That reproduces the "nightly +
  rustfmt + clippy" contract devenv promises, without needing devenv's Nix
  machinery inside a CI container.
- `rusqlite` is built with the `bundled` feature (`Cargo.toml`), i.e. it
  compiles its own vendored SQLite from source — no system
  `libsqlite3-dev` needed.
- `self_update` is built with `rustls`, not `native-tls` — no system
  OpenSSL headers needed.
- What's left (a C compiler + `pkg-config`, for the handful of `-sys`
  crates that shell out to `cc`) is preinstalled on the `ubuntu-latest`
  runner image (`build-essential`, `pkg-config`).

Verified locally: `cargo build --locked --all-targets --all-features`
succeeds under the plain `rustup`-managed nightly with no extra system
packages beyond what a bare Ubuntu dev-tools install provides (this
sandbox's devenv shell only adds `gcc`/`pkg-config`/`openssl`/`sqlite`,
all of which are either unnecessary per the bundeled-feature reasoning above
or already present on GitHub's runner image).

If a future dependency genuinely needs a system library that devenv
provides and the runner image doesn't have, install it explicitly with
`apt-get install -y <pkg>` in the relevant job — don't reach for devenv/Nix
in CI, and don't let this section go stale if that happens.

## Test sharding, and why it's computed rather than hardcoded

`tests/*.rs` is 105 files (each a separately compiled+linked integration
test binary), long enough that a previous attempt to run the whole suite as
one blocking `cargo test` call outlived the caller's patience/signal budget.
The `test` job shards by listing `tests/*.rs` at run time (sorted, `index %
4`), not from a hardcoded list — adding or removing a test file doesn't
require editing the workflow. `#[ignore]`d tests (the
`bench_*`/`benchmark_*.rs` performance-comparison suites, opt-in via
`-- --ignored` per their own doc comments) are skipped by `cargo test`'s
default behavior, but still get *compiled* in whichever shard contains them,
so a build break there is still caught.

The shard-selection script passes filenames to `cargo` as literal `argv`
elements via a bash array (`cargo "${args[@]}"`), never through a
re-parsed string — a PR that added a test file with a
shell-metacharacter-laden name would otherwise be able to turn "pick which
tests to run" into "run arbitrary shell in the gate," which is the same
class of hazard (attacker-controlled data reaching a shell) as splicing
`${{ github.event.pull_request.title }}` directly into a `run:` block. No
step in this workflow does the latter; every value that originates from the
PR/event context and is used in a script is passed through `env:` first.

**Measured hazard, not fixed by this PR:** `tests/e2e_installer.rs`
contains `e2e_installer_full_install_and_verify`, which (when both `bash`
and network are available, which is the normal case on a GitHub-hosted
runner) shells out to this repo's `install.sh`, which — because no
prebuilt release binary matches this checkout — falls back to a full
`cargo build --release` of a fetched source tree. In this sandbox that
fetched tree turned out to be a much larger, unrelated dependency graph
(pulling in crates this repo's own `Cargo.toml` does not use at all, e.g.
`fsqlite`/`asupersync`/`mimalloc`) and took several minutes by itself with
LTO + `codegen-units=1`. Whichever shard draws `e2e_installer.rs` will be
the long pole of the `test` job by a wide margin, and it depends on
network access to a resource outside this repo's control — a source of
both slowness and potential flakiness that has nothing to do with whether
the PR under test is correct. This PR does not change that test (it is
out of scope for a CI-gate PR to also start editing the test suite's
behavior), but the shard timeout budget below accounts for it, and a
reasonable follow-up would be gating that one test behind the same
network-required `#[ignore]` convention `e2e_installer_version_resolution_github_api`
in the same file already uses.

## Does `ci.yml` agree with `scripts/ci-local.sh` about what "passing" means?

The project leader asked for this comparison explicitly, including the rows
that agree — agreement is what makes this evidence rather than "the one
divergence I happened to notice."

| Dimension | `scripts/ci-local.sh` | `ci.yml` | Agree? |
|---|---|---|---|
| Toolchain channel | Not pinned by the script itself; relies on `rust-toolchain.toml` + `rustup` being on `PATH` (true inside devenv) | Explicit `rustup show` against the same `rust-toolchain.toml` | **Agree** (same source of truth; script additionally assumes devenv/rustup is already active, which CI makes explicit) |
| `fmt` | `cargo fmt --all -- --check` | `cargo fmt --all -- --check` | **Agree**, identical command |
| `clippy --all-features` | `cargo clippy --all-targets --all-features -- -D warnings` | `cargo clippy --locked --all-targets --all-features -- -D warnings` | Agree in substance; CI adds `--locked` (fails loudly instead of silently updating `Cargo.lock`, no behavior change while the lockfile is already consistent) |
| `clippy --no-default-features` | same, `--no-default-features` | same + `--locked` | Same note as above |
| Build/check | `cargo check --all-targets --all-features` (type-check only) | `cargo build --locked --all-targets --all-features` (compiles **and links**) | **Diverge, CI is stricter**: `build` can catch link-time failures `check` cannot. Not a hole — the stronger check subsumes the weaker one. |
| Integration tests, all-features | One call: `cargo test --all-features -- --nocapture` (same tests, output always shown) | Same test set, split across 4 shards, default output capture (shown only on failure) | Agree on which tests run and what "pass" means; differ only in execution strategy and log verbosity, not semantics |
| Integration tests, no-default-features | `cargo test --no-default-features` (note: script does *not* pass `--nocapture` here, an asymmetry in the script itself) | Same test set, sharded, `--locked` added | Agree in substance |
| Doc tests | `cargo test --doc` — **no feature flag**, so default features (`self_update` on, since `default = ["self_update"]`) | Runs under **both** `--all-features` and `--no-default-features` | **Diverge, CI is a superset.** Today `--all-features` and bare-default are identical outcomes because `self_update` is this crate's only optional feature and it's already on by default — but that's a coincidence of the current feature list, not something the script asserts. If a second optional feature is ever added without updating `ci-local.sh`, the script's doc-test pass would silently stop exercising it while `ci.yml`'s `--all-features` leg would not. CI additionally runs doc tests under `--no-default-features`, which the script never does at all. |
| `-D warnings` on clippy | Yes | Yes | **Agree** |
| Env vars | None set by the script | `CARGO_TERM_COLOR=always`, `CARGO_INCREMENTAL=0` | Agree functionally — neither affects pass/fail, only build log color and incremental-cache bookkeeping (which buys nothing on ephemeral CI runners) |
| Working directory | Implicit repo root (cargo auto-detects the workspace regardless of cwd within it) | Explicit: `actions/checkout` puts the tree at `$GITHUB_WORKSPACE`, steps run there by default | **Agree** |
| Test parallelism | Implicit, `cargo test`'s default (≈ host CPU count) | Same, implicit | Agree on mechanism; **operational risk, not a semantic divergence** — GitHub's `ubuntu-latest` runners have far fewer cores than most dev machines, and this repo has at least one concurrency-sensitive suite (`tests/e2e_concurrency.rs`); a test that's timing-sensitive under high local parallelism could behave differently under CI's parallelism. Worth watching for flakiness once real Actions runs exist; not something this PR can resolve without a live run. |

Net: the one place `ci.yml` was found to check *less* than the script
(doc tests only under one feature profile) has been closed by adding the
`--no-default-features` doc-test leg — chosen deliberately over the
alternative of narrowing `ci-local.sh` to match, per the project leader's
ruling, because narrowing the stricter definition of "passing" would have
deleted real coverage rather than added it. Every other divergence found
is either non-behavioral (flags, verbosity, env) or CI being *stricter*
(build vs check, superset feature coverage on doc tests) — the direction
that's safe to leave as-is.

## Verification: what was proved versus what was argued

**Proved** (commands run against this branch's tree — identical to `main`'s
for every file these checks touch, since this PR added only
`.github/workflows/ci.yml` and this doc before these commands were run —
using the same nightly toolchain the workflow installs, via `devenv shell`):

- `cargo fmt --all -- --check` — **exit 1**, ~2854 lines of diff. Backlog is
  real, not inferred from the missing-workflow situation.
- `cargo check --all-targets --all-features` — exit 0, ~2 min.
- `cargo clippy --locked --all-targets --all-features -- -D warnings` —
  exit 0, ~58s.
- `cargo clippy --locked --all-targets --no-default-features -- -D
  warnings` — exit 0, ~67s.
- `cargo build --locked --all-targets --no-default-features` — exit 0,
  ~6m23s cold (this and everything below ran serially, back to back, in
  one 46m39s wall-clock chain, so most of these timings include queueing
  behind the step before them, not isolated cold-cache time).
- `cargo test --locked --all-features` (unsharded — every one of the 105
  `tests/*.rs` files, plus `--lib` and the crate's doctests, since a bare
  `cargo test` with no `--lib`/`--test`/`--doc` filter runs all three) —
  **exit 0, explicitly observed** (`EXIT(test all-features full)=0`),
  including the `Doc-tests beads_rust ... 0 failed` block inside that same
  run. This entails (does not just argue) that `cargo build --locked
  --all-targets --all-features`, `cargo test --lib --all-features`, and
  `cargo test --doc --all-features` all pass too — cargo cannot run tests
  it hasn't first built, and the full unfiltered run exercises the same
  lib-test and doc-test code the narrower invocations would.
- `cargo test --locked --no-default-features` (full suite, same scope as
  above) — **exit 0, explicitly observed**
  (`EXIT(test no-default-features full)=0`), same entailment for `build`/
  `--lib`/`--doc` under this feature profile.
- `cargo test --locked --no-default-features --doc` — exit 0, explicitly
  observed (redundant with the point above, run anyway; no new
  information, just confirmation).
- This run is also what surfaced the `e2e_installer_full_install_and_verify`
  network+nested-build hazard documented earlier in this file — found by
  running the real suite, not inferred from reading the test names.
- The workflow YAML parses under a real parser (`yq`, mikefarah/yq v4) and
  is accepted by `actionlint` v1.7.12 with zero findings.
- **Positive control on the parser/linter themselves**: both `yq` and
  `actionlint` were first run against deliberately-broken YAML (a
  malformed flow sequence for `yq`; a scalar-where-mapping-expected `on:`
  block, a raw `${{ github.event.pull_request.title }}` splice into a
  `run:` block, and an unquoted shell variable for `actionlint`) and both
  rejected it with specific, correct diagnostics — including `actionlint`
  independently flagging the exact "untrusted input into a `run:` block"
  hazard this workflow is required to avoid, unprompted, by name, with a
  link to GitHub's mitigation doc. Only after that did the real `ci.yml`
  get checked, and both tools returned clean.

**Argued, not proved** (cannot be proved until GitHub Actions recovers from
its outage):

- That the workflow behaves identically when run *by GitHub Actions*
  specifically — Actions-specific behavior (runner environment quirks,
  `actions/cache` restore/save semantics across a real matrix, actual wall-
  clock time under `ubuntu-latest`'s real CPU/network characteristics) was
  not and could not be exercised. The local runs above prove the
  *commands* are correct and the *code* passes them; they do not prove the
  *workflow file* orchestrates them correctly end to end on GitHub's
  infrastructure.
- Cache hit/miss behavior and the resulting wall-clock time per job.
  Timeout budgets (`timeout-minutes: 45` for test shards, `30` for
  clippy/build/lib+doc) are deliberately conservative estimates based on
  local compile times on a much larger machine (16 cores) than
  `ubuntu-latest` provides (typically 4); they may need tightening or
  loosening once real run data exists.
- That the required-status-check names above are matched by GitHub
  *exactly* as written once a real run reports them — job `name:` fields
  with matrix interpolation were written to produce these strings, but
  this has not been observed against a live Checks API response.

## Proving the gate can actually fail: the mutation recipe

The property that matters is not "the workflow parses" — it's "the workflow
turns red when the code is broken." This cannot be demonstrated without a
working Actions run, so here is the exact, reproducible recipe for whoever
runs it once the outage clears. Do this on a disposable branch off this
one, **not** on `main`.

### Mutation 1 — prove `build`, both `clippy` legs, and every `test` shard can fail

Append to the end of `src/lib.rs` (after the last `pub mod` line):

```rust
#[allow(dead_code)]
fn ci_gate_mutation_probe_compile_break() -> i32 {
    let probe: i32 = "this is a type error, not a string";
    probe
}
```

**Expected failing jobs:** `build`, both `clippy (*)` jobs, and **every**
`test (*)` and `test (lib + doctests, *)` job — because this is a
compile error in the library crate itself, everything that depends on the
crate compiling fails at the same step, before any test or lint logic even
runs.

**Expected diagnostic:** a `rustc`/`cargo` `error[E0308]: mismatched types`
pointing at `src/lib.rs`, the `ci_gate_mutation_probe_compile_break`
function, `expected i32, found &str`. The `fmt` job is unaffected (rustfmt
doesn't type-check).

Revert by deleting the function.

### Mutation 2 — prove `clippy` catches what `build`/`test` do not

On a separate probe (so it isolates from Mutation 1), append instead:

```rust
#[allow(dead_code)]
pub fn ci_gate_mutation_probe_lint_break(x: i32) -> i32 {
    return x;
}
```

This compiles and runs fine — `build` and every `test` job stay **green**.

**Expected failing jobs:** both `clippy (all-features)` and
`clippy (no-default-features)` only.

**Expected diagnostic:** `error: unneeded \`return\` statement` (lint:
`clippy::needless_return`), promoted from warning to error by this
workflow's `-- -D warnings`, pointing at
`ci_gate_mutation_probe_lint_break` in `src/lib.rs`. This is the
differential proof that the `clippy` jobs are doing real, independent work
— a mutation that is invisible to `cargo build`/`cargo test` is still
caught.

Revert by deleting the function.

Either mutation, applied to a real PR branch once Actions is out of
`major_outage`, is sufficient to demonstrate the gate is a gate and not
decoration. Neither has been applied here — this PR does not modify any
`.rs` file — so as of this writing the claim "the gate can fail" is
supported by the reasoning above (the commands are real, unsuppressed, and
proven to currently pass; a targeted change to what they check is
proven-in-principle to make them fail) but not by an observed red run.
