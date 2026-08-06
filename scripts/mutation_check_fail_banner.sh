#!/usr/bin/env bash
# Mutation harness: break the banner one way at a time and confirm the tests
# notice. Run from the repo root. Restores the tree after each mutation.
set -u
export PATH="/home/toad/bit/beads_rust/.devenv/profile/bin:$PATH"

apply() { python3 - "$@" ; }

restore() { git checkout -- src/ ; }

run_tests() { # $@ = extra args to cargo test
  cargo test --test e2e_fail_banner --test e2e_broken_pipe -j 2 -- --test-threads=2 --skip common:: 2>&1 \
    | grep -E "^test [a-z_]+ \.\.\.|^test result:|^error" 
}

report() { echo "=================== $1 ==================="; }

mutate_and_test() {
  local name="$1"; local script="$2"
  report "$name"
  python3 -c "$script" || { echo "MUTATION SCRIPT FAILED"; restore; return 1; }
  run_tests
  restore
}

# --- M1: banner emitted FIRST instead of last (the placebo implementation) ---
mutate_and_test "M1 banner emitted FIRST (before the error envelope)" '
import re
p="src/main.rs"; s=open(p).read()
old="""    let structured = StructuredError::from_error(err);
    let exit_code = structured.code.exit_code();
"""
new="""    let structured = StructuredError::from_error(err);
    let exit_code = structured.code.exit_code();
    beads_rust::exit::emit_exit_banner(ExitKind::Failure, structured.code.as_str(), exit_code);
"""
assert old in s
s=s.replace(old,new)
s=s.replace("    exit_with_status(exit_code, ExitKind::Failure, structured.code.as_str());","    std::process::exit(exit_code);")
open(p,"w").write(s)
'

# --- M2: no stdout flush before the banner ---
mutate_and_test "M2 stdout NOT flushed before the banner" '
p="src/exit.rs"; s=open(p).read()
old="    let _ = std::io::stdout().flush();\n"
assert old in s
s=s.replace(old,"",1)
s=s.replace("use std::io::Write;","use std::io::Write;\n#[allow(unused_imports)]\nuse std::io::Write as _;")
open(p,"w").write(s)
'

# --- M3: one exit path skips the banner (doctor) ---
mutate_and_test "M3 doctor exit path bypasses the funnel" '
p="src/cli/commands/doctor.rs"; s=open(p).read()
old="""    if !report.ok {
        exit_with_status(1, ExitKind::Failure, DOCTOR_FAILED);
    }"""
new="""    if !report.ok {
        std::process::exit(1);
    }"""
assert old in s
open(p,"w").write(s.replace(old,new))
'

# --- M4: clap usage errors bypass the funnel (Cli::parse) ---
mutate_and_test "M4 clap usage error bypasses the funnel" '
p="src/main.rs"; s=open(p).read()
assert "let cli = parse_cli();" in s
open(p,"w").write(s.replace("let cli = parse_cli();","let cli = Cli::parse();"))
'

# --- M5: banner is unconditional, including on exit 0 ---
mutate_and_test "M5 banner emitted even on exit 0" '
p="src/exit.rs"; s=open(p).read()
old="""    if status != 0 {
        emit_exit_banner(kind, label, status);
    }
    std::process::exit(status)"""
new="""    emit_exit_banner(kind, label, status);
    std::process::exit(status)"""
assert old in s
open(p,"w").write(s.replace(old,new))
'

# --- M6: banner on stdout instead of stderr ---
mutate_and_test "M6 banner written to stdout" '
p="src/exit.rs"; s=open(p).read()
old="    let mut stderr = std::io::stderr().lock();"
new="    let mut stderr = std::io::stdout().lock();"
assert old in s
open(p,"w").write(s.replace(old,new))
'

# --- M7: gated on isatty (the forbidden pipe-detection design) ---
mutate_and_test "M7 banner gated on stderr being a terminal" '
p="src/exit.rs"; s=open(p).read()
old="pub fn emit_exit_banner(kind: ExitKind, label: &str, status: i32) {"
new="""pub fn emit_exit_banner(kind: ExitKind, label: &str, status: i32) {
    if !std::io::IsTerminal::is_terminal(&std::io::stderr()) {
        return;
    }"""
assert old in s
open(p,"w").write(s.replace(old,new))
'

# --- M8: panic path loses the banner ---
mutate_and_test "M8 fatal panic emits no banner" '
p="src/main.rs"; s=open(p).read()
old="        if beads_rust::exit::panic_is_fatal() {"
new="        if false && beads_rust::exit::panic_is_fatal() {"
assert old in s
open(p,"w").write(s.replace(old,new))
'

# --- M9: Notice wording claims FAILED (unit test) ---
report "M9 Notice wording claims FAILED (lib unit tests)"
python3 -c '
p="src/exit.rs"; s=open(p).read()
old="""        ExitKind::Notice => format!("{name}: {label} (exit {status})"),"""
new="""        ExitKind::Notice => format!("{name}: FAILED ({label}, exit {status})"),"""
assert old in s
open(p,"w").write(s.replace(old,new))
'
cargo test --lib exit:: -j 2 -- --test-threads=2 2>&1 | grep -E "^test |^test result:|^error"
restore

echo "=================== control: unmutated tree ==================="
run_tests
cargo test --lib exit:: -j 2 -- --test-threads=2 2>&1 | grep -E "^test result:"
