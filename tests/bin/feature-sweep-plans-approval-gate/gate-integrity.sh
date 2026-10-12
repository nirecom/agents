#!/usr/bin/env bash
# Tests: bin/sweep-plans.sh, bin/sweep-plans/gate-artifact.js
# Tags: scope:common, TL2, sweep, plans, approval-gate, gate-signature, table-driven, path-normalization, pwsh-not-required
# Part file of tests/bin/feature-sweep-plans-approval-gate.sh (sourced; uses its helpers).
# Gate integrity: plans-dir binding (G17), the malformed-artifact matrix (G19; folds the
# former G11 direct call and G12 tamper cases), equivalent directory forms (G20) and a
# pass 2 whose plans dir is gone (G21) and a symlinked plans dir retargeted between passes
# (G22). Every row runs pass 2 through bin/sweep-plans.sh.

# G17: the gate binds the full resolved plans dir — same basename under another parent must not pass.
case_begin "G17-plans-dir-mismatch" "bin/sweep-plans.sh"
reset_gate
mkdir -p "$T_ROOT/g17x/plans" "$T_ROOT/g17y/plans"
P1="$(cd "$T_ROOT/g17x/plans" && pwd)"; P2="$(cd "$T_ROOT/g17y/plans" && pwd)"
check "G17 precondition: P1 and P2 share a basename" "${P1##*/}" "${P2##*/}"
for n in "${GA[@]}"; do
  printf 'x\n' > "$P1/$n"; backdate_days 60 "$P1/$n"
  printf 'x\n' > "$P2/$n"; touch -r "$P1/$n" "$P2/$n"
  check "G17 precondition: $n mtime matches across P1 and P2" "$(mtime_of "$P1/$n")" "$(mtime_of "$P2/$n")"
done
printf 'x\n' > "$P2/$RAW_A"; backdate_days 60 "$P2/$RAW_A"
pass1 "$P1"
check "G17 pass 1 against P1 exits 0" "0" "$RC"
if [[ -f "$GATE_FILE" ]]; then
  check "G17 the artifact records P1's full path as its plans dir" "1" "$(recorded_dir_is "$P1")"
else
  fail "G17 the artifact records P1 as its plans dir" "no gate artifact"
fi
pass2 "$P2" "$GID" "$(approve_file "$A")"
check "G17 pass 2 against P2 exits 2" "2" "$RC"
has_line "G17 the error names the mismatched gate artifact" "$ERR" \
  "^ERROR: sweep-plans: approval gate artifact missing or mismatched; nothing deleted$"
expect_all_present "G17 P2 (non-plan included)" "$P2" "${GA[@]}" "$RAW_A"
expect_all_present "G17 P1" "$P1" "${GA[@]}"
case_end

# ── G19: malformed gate artifact matrix ──────────────────────────────────────
# mutation: drop N | set N <line> | swap N M | row-epoch | row-file-epoch | row-basename
#           | row-add | row-drop | truncate | remove | none
# <line> placeholders: @ID@ @NONCE@ @NONCE_FLIP@ @DIR@ @OTHER@ (another dir), @SP@ (a space).
# gate-id: recorded (pass 1's) | other (well-formed, different) | nothex | reforged
#          (recomputed from the mutated artifact, so only the plans-dir check can reject it).
declare -A G19_MUT=() G19_GID=() G19_RAN=()
G19_ORDER=()
while IFS='|' read -r name mut gid; do
  [[ -z "${name//[[:space:]]/}" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; gid="${gid//[[:space:]]/}"
  mut="${mut#"${mut%%[![:space:]]*}"}"; mut="${mut%"${mut##*[![:space:]]}"}"
  G19_MUT["$name"]="$mut"; G19_GID["$name"]="$gid"; G19_ORDER+=("$name")
done <<'TABLE'
header-missing-line1           | drop 1                          | recorded
header-missing-line2           | drop 2                          | recorded
header-missing-line3           | drop 3                          | recorded
gate-id-wrong-prefix           | set 1 # gateid @ID@             | recorded
gate-id-empty-value            | set 1 # gate-id@SP@             | recorded
gate-id-extra-field            | set 1 # gate-id @ID@ extra      | recorded
nonce-wrong-prefix             | set 2 # nonce: @NONCE@          | recorded
nonce-empty-value              | set 2 # nonce@SP@               | recorded
nonce-extra-field              | set 2 # nonce @NONCE@ extra     | recorded
plans-dir-wrong-prefix         | set 3 # plansdir @DIR@          | recorded
plans-dir-empty-value          | set 3 # plans-dir@SP@           | recorded
plans-dir-extra-field          | set 3 # plans-dir @DIR@ extra   | recorded
header-order-swapped-1-2       | swap 1 2                        | recorded
header-order-swapped-2-3       | swap 2 3                        | recorded
gate-id-mismatch               | none                            | other
gate-id-arg-not-hex            | none                            | nothex
nonce-tampered                 | set 2 # nonce @NONCE_FLIP@      | recorded
row-newest-epoch-changed       | row-epoch                       | recorded
row-file-epoch-changed         | row-file-epoch                  | recorded
row-basename-changed           | row-basename                    | recorded
row-added                      | row-add                         | recorded
row-removed                    | row-drop                        | recorded
plans-dir-other-dir            | set 3 # plans-dir @OTHER@       | recorded
plans-dir-other-dir-reforged   | set 3 # plans-dir @OTHER@       | reforged
artifact-empty                 | truncate                        | recorded
artifact-missing               | remove                          | recorded
TABLE

REFORGE_JS="$T_ROOT/reforge.js"
cat > "$REFORGE_JS" <<'JS'
// reforge.js <artifact> — rewrite line 1 with the id recomputed from nonce + plans-dir + rows; print it.
const fs = require("fs"); const crypto = require("crypto");
const f = process.argv[2]; const t = fs.readFileSync(f, "utf8");
const m = /^# gate-id [^\n]*\n# nonce ([0-9a-f]+)\n# plans-dir ([^\n]*)\n/.exec(t);
if (!m) process.exit(1);
const rows = t.slice(m[0].length);
const id = crypto.createHash("sha256").update(m[1] + m[2] + rows).digest("hex").slice(0, 32);
fs.writeFileSync(f, `# gate-id ${id}\n# nonce ${m[1]}\n# plans-dir ${m[2]}\n${rows}`);
process.stdout.write(id);
JS
reforge() { node "$(np "$REFORGE_JS")" "$(np "$1")"; }

# _row_index <token> — index in L of that token's row (rows start at index 3).
_row_index() {
  local i
  for (( i = 3; i < ${#L[@]}; i++ )); do
    if [[ "${L[i]%%"$TAB"*}" == "$1" ]]; then printf '%d' "$i"; return 0; fi
  done
  return 1
}

# art_mutate <mutation> — apply one table mutation to $GATE_FILE; rc 1 when it cannot apply.
art_mutate() {
  local op n1 rest text i t ne l first e
  read -r op n1 rest <<< "$1"
  local -a L=()
  mapfile -t L < "$GATE_FILE"
  local id="${L[0]#\# gate-id }" nonce="${L[1]#\# nonce }" dir="${L[2]#\# plans-dir }"
  local flip="${nonce%?}"
  if [[ "${nonce: -1}" == "0" ]]; then flip+="1"; else flip+="0"; fi
  case "$op" in
    none) return 0 ;;
    remove) rm -f "$GATE_FILE"; return 0 ;;
    truncate) : > "$GATE_FILE"; return 0 ;;
    drop) unset 'L[n1-1]' ;;
    set)
      text="${rest//@ID@/$id}"; text="${text//@NONCE_FLIP@/$flip}"; text="${text//@NONCE@/$nonce}"
      text="${text//@DIR@/$dir}"; text="${text//@OTHER@/$G19_OTHER}"; text="${text//@SP@/ }"
      L[n1-1]="$text"
      ;;
    swap) t="${L[n1-1]}"; L[n1-1]="${L[rest-1]}"; L[rest-1]="$t" ;;
    row-epoch|row-file-epoch|row-basename)
      i="$(_row_index "$A")" || return 1
      IFS="$TAB" read -r t ne l <<< "${L[i]}"
      first="${l%%,*}"; e="${first##*:}"
      case "$op" in
        row-epoch) ne=$(( ne + 1 )) ;;
        row-file-epoch)
          l="${first%:*}:$(( e + 1 ))${l:${#first}}"
          ;;
        row-basename) [[ "$l" == *"$A-intent.md:"* ]] || return 1; l="${l/"$A-intent.md:"/"$A-detail.md:"}" ;;
      esac
      L[i]="$t$TAB$ne$TAB$l"
      ;;
    row-add) L+=("$C${TAB}1${TAB}$C-intent.md:1") ;;
    row-drop) i="$(_row_index "$B")" || return 1; unset 'L[i]' ;;
    *) return 1 ;;
  esac
  printf '%s\n' "${L[@]}" > "$GATE_FILE"
}

# g19_run <row-name> — restore pass 1's artifact, mutate it, run pass 2, assert the refusal.
g19_run() {
  local name="$1" mut gid
  if [[ -z "${G19_MUT[$name]+x}" ]]; then fail "G19 $name" "row not in the table"; return; fi
  G19_RAN["$name"]=$(( ${G19_RAN[$name]:-0} + 1 ))
  mut="${G19_MUT[$name]}"; gid="${G19_GID[$name]}"
  cp "$G19_PRISTINE" "$GATE_FILE"
  mk_old "$G19_P" "$RAW_A"
  if ! art_mutate "$mut"; then fail "G19 $name" "mutation '$mut' could not be applied"; return; fi
  if [[ "$mut" != none && "$mut" != remove ]]; then
    if cmp -s "$G19_PRISTINE" "$GATE_FILE"; then fail "G19 $name precondition: the artifact was mutated"; else pass "G19 $name precondition: the artifact was mutated"; fi
  fi
  case "$gid" in
    recorded) gid="$G19_GID0" ;;
    other) gid="ffffffffffffffffffffffffffffffff" ;;
    nothex) gid="not-a-hex-gate-id" ;;
    reforged)
      gid="$(reforge "$GATE_FILE")" || { fail "G19 $name" "reforge failed"; return; }
      if [[ "$gid" =~ ^[0-9a-f]{32}$ && "$gid" != "$G19_GID0" ]]; then pass "G19 $name precondition: a consistent new id"; else fail "G19 $name precondition: a consistent new id" "got=$gid"; fi
      ;;
  esac
  [[ "$gid" != "$G19_GID0" || "${G19_GID[$name]}" == recorded ]] || fail "G19 $name precondition: the passed id differs"
  pass2 "$G19_P" "$gid" "$G19_AF"
  check "G19 $name exits 2" "2" "$RC"
  check "G19 $name prints exactly the gate ERROR line on stderr" "$GATE_ERR_LINE" "$ERR"
  expect_all_present "G19 $name" "$G19_P" "${GA[@]}" "${GB[@]}" "$RAW_A"
  if [[ "$mut" != remove ]]; then expect_present "G19 $name leaves the gate artifact unconsumed" "$GATE_FILE"; fi
}

case_begin "G19-setup-pass1-and-oracle" "bin/sweep-plans/gate-artifact.js"
reset_gate
G19_P="$(new_dir g19)"; mk_old "$G19_P" "${GA[@]}" "${GB[@]}"
mkdir -p "$T_ROOT/g19-other"; G19_OTHER="$(np "$(cd "$T_ROOT/g19-other" && pwd)")"
G19_AF="$(approve_file "$A")"
pass1 "$G19_P"; G19_GID0="$GID"
check "G19 setup: pass 1 exits 0" "0" "$RC"
has_line "G19 setup: pass 1 recorded a 32-hex gate id" "$G19_GID0" "^[0-9a-f]{32}$"
G19_PRISTINE="$T_ROOT/g19-pristine.tsv"
cp "$GATE_FILE" "$G19_PRISTINE" 2>/dev/null || fail "G19 setup: no gate artifact to keep"
has_line "G19 setup: the artifact carries session A's row" "$(cat "$G19_PRISTINE")" "^$A$TAB[0-9]+$TAB"
has_line "G19 setup: the artifact carries session B's row" "$(cat "$G19_PRISTINE")" "^$B$TAB[0-9]+$TAB"
cp "$G19_PRISTINE" "$T_ROOT/g19-oracle.tsv"
check "G19 setup: the reforge oracle reproduces pass 1's id" "$G19_GID0" "$(reforge "$T_ROOT/g19-oracle.tsv")"
case_end

case_begin "G19-header-missing-line1" "bin/sweep-plans/gate-artifact.js"
g19_run header-missing-line1
case_end
case_begin "G19-header-missing-line2" "bin/sweep-plans/gate-artifact.js"
g19_run header-missing-line2
case_end
case_begin "G19-header-missing-line3" "bin/sweep-plans/gate-artifact.js"
g19_run header-missing-line3
case_end
case_begin "G19-gate-id-wrong-prefix" "bin/sweep-plans/gate-artifact.js"
g19_run gate-id-wrong-prefix
case_end
case_begin "G19-gate-id-empty-value" "bin/sweep-plans/gate-artifact.js"
g19_run gate-id-empty-value
case_end
case_begin "G19-gate-id-extra-field" "bin/sweep-plans/gate-artifact.js"
g19_run gate-id-extra-field
case_end
case_begin "G19-nonce-wrong-prefix" "bin/sweep-plans/gate-artifact.js"
g19_run nonce-wrong-prefix
case_end
case_begin "G19-nonce-empty-value" "bin/sweep-plans/gate-artifact.js"
g19_run nonce-empty-value
case_end
case_begin "G19-nonce-extra-field" "bin/sweep-plans/gate-artifact.js"
g19_run nonce-extra-field
case_end
case_begin "G19-plans-dir-wrong-prefix" "bin/sweep-plans/gate-artifact.js"
g19_run plans-dir-wrong-prefix
case_end
case_begin "G19-plans-dir-empty-value" "bin/sweep-plans/gate-artifact.js"
g19_run plans-dir-empty-value
case_end
case_begin "G19-plans-dir-extra-field" "bin/sweep-plans/gate-artifact.js"
g19_run plans-dir-extra-field
case_end
case_begin "G19-header-order-swapped-1-2" "bin/sweep-plans/gate-artifact.js"
g19_run header-order-swapped-1-2
case_end
case_begin "G19-header-order-swapped-2-3" "bin/sweep-plans/gate-artifact.js"
g19_run header-order-swapped-2-3
case_end
case_begin "G19-gate-id-mismatch" "bin/sweep-plans/gate-artifact.js"
g19_run gate-id-mismatch
case_end
case_begin "G19-gate-id-arg-not-hex" "bin/sweep-plans.sh"
g19_run gate-id-arg-not-hex
case_end
case_begin "G19-nonce-tampered" "bin/sweep-plans/gate-artifact.js"
g19_run nonce-tampered
case_end
case_begin "G19-row-newest-epoch-changed" "bin/sweep-plans/gate-artifact.js"
g19_run row-newest-epoch-changed
case_end
case_begin "G19-row-file-epoch-changed" "bin/sweep-plans/gate-artifact.js"
g19_run row-file-epoch-changed
case_end
case_begin "G19-row-basename-changed" "bin/sweep-plans/gate-artifact.js"
g19_run row-basename-changed
case_end
case_begin "G19-row-added" "bin/sweep-plans/gate-artifact.js"
g19_run row-added
case_end
case_begin "G19-row-removed" "bin/sweep-plans/gate-artifact.js"
g19_run row-removed
case_end
case_begin "G19-plans-dir-other-dir" "bin/sweep-plans/gate-artifact.js"
g19_run plans-dir-other-dir
case_end
case_begin "G19-plans-dir-other-dir-reforged" "bin/sweep-plans/gate-artifact.js"
g19_run plans-dir-other-dir-reforged
case_end
case_begin "G19-artifact-empty" "bin/sweep-plans/gate-artifact.js"
g19_run artifact-empty
case_end
case_begin "G19-artifact-missing" "bin/sweep-plans.sh"
g19_run artifact-missing
case_end

# ── G20: equivalent spellings of one plans dir (positive controls) ──────────
# pass 1 and pass 2 resolve the same dir under different spellings; the gate must accept.
# needs: win = the form exists only where cygpath does (Git Bash / MSYS); any = every host.
declare -A G20_FORM1=() G20_FORM2=() G20_NEEDS=() G20_RAN=()
G20_ORDER=()
while IFS='|' read -r name f1 f2 needs; do
  [[ -z "${name//[[:space:]]/}" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"
  G20_FORM1["$name"]="${f1//[[:space:]]/}"; G20_FORM2["$name"]="${f2//[[:space:]]/}"
  G20_NEEDS["$name"]="${needs//[[:space:]]/}"; G20_ORDER+=("$name")
done <<'TABLE'
plain-then-trailing-slash        | plain   | plain-slash   | any
msys-then-mixed                  | msys    | mixed         | win
mixed-then-native                | mixed   | native        | win
native-then-msys                 | native  | msys          | win
mixed-then-lowercase-drive       | mixed   | lower         | win
lowercase-drive-then-msys        | lower   | msys          | win
msys-then-trailing-slash         | msys    | msys-slash    | win
mixed-then-trailing-slash        | mixed   | mixed-slash   | win
native-then-trailing-backslash   | native  | native-bslash | win
TABLE

# dir_form <form> <dir> — <dir> spelled as <form>.
dir_form() {
  local m d
  case "$1" in
    plain) printf '%s' "$2"; return ;;
    plain-slash) printf '%s/' "$2"; return ;;
  esac
  m="$(cygpath -m "$2")"; d="$(printf '%s' "${m:0:1}" | tr '[:upper:]' '[:lower:]')"
  case "$1" in
    msys) printf '/%s/%s' "$d" "${m:3}" ;;
    msys-slash) printf '/%s/%s/' "$d" "${m:3}" ;;
    mixed) printf '%s' "$m" ;;
    mixed-slash) printf '%s/' "$m" ;;
    native) cygpath -w "$2" ;;
    native-bslash) printf '%s\\' "$(cygpath -w "$2")" ;;
    lower) printf '%s%s' "$d" "${m:1}" ;;
  esac
}

# g20_run <row-name> — pass 1 under one spelling, pass 2 under another; the gate accepts and deletes.
g20_run() {
  local name="$1" p f1 f2 canon
  if [[ -z "${G20_FORM1[$name]+x}" ]]; then fail "G20 $name" "row not in the table"; return; fi
  G20_RAN["$name"]=$(( ${G20_RAN[$name]:-0} + 1 ))
  if [[ "${G20_NEEDS[$name]}" == win ]] && ! command -v cygpath >/dev/null 2>&1; then
    skip "G20 $name (no cygpath: the drive-letter spellings do not exist on this host)"; return
  fi
  reset_gate
  p="$(new_dir g20)"; mk_old "$p" "${GA[@]}"; p="$(cd "$p" && pwd)"
  f1="$(dir_form "${G20_FORM1[$name]}" "$p")"; f2="$(dir_form "${G20_FORM2[$name]}" "$p")"
  if [[ "$f1" != "$f2" ]]; then pass "G20 $name precondition: the two spellings differ"; else fail "G20 $name precondition: the two spellings differ" "both=$f1"; fi
  canon="$(np "$p")"
  pass1 "$f1"
  check "G20 $name pass 1 ($f1) exits 0" "0" "$RC"
  check "G20 $name the artifact records the canonical plans dir" "# plans-dir $canon" "$(sed -n 3p "$GATE_FILE" 2>/dev/null | tr -d '\r')"
  pass2 "$f2" "$GID" "$(approve_file "$A")"
  check "G20 $name pass 2 ($f2) exits 0" "0" "$RC"
  lacks_line "G20 $name pass 2 prints no gate ERROR" "$ERR" "^ERROR: sweep-plans:"
  for n in "${GA[@]}"; do expect_gone "G20 $name approved A: $n is removed" "$p/$n"; done
  expect_gone "G20 $name the gate artifact is consumed" "$GATE_FILE"
}

case_begin "G20-plain-then-trailing-slash" "bin/sweep-plans.sh"
g20_run plain-then-trailing-slash
case_end
case_begin "G20-msys-then-mixed" "bin/sweep-plans/gate-artifact.js"
g20_run msys-then-mixed
case_end
case_begin "G20-mixed-then-native" "bin/sweep-plans/gate-artifact.js"
g20_run mixed-then-native
case_end
case_begin "G20-native-then-msys" "bin/sweep-plans/gate-artifact.js"
g20_run native-then-msys
case_end
case_begin "G20-mixed-then-lowercase-drive" "bin/sweep-plans/gate-artifact.js"
g20_run mixed-then-lowercase-drive
case_end
case_begin "G20-lowercase-drive-then-msys" "bin/sweep-plans/gate-artifact.js"
g20_run lowercase-drive-then-msys
case_end
case_begin "G20-msys-then-trailing-slash" "bin/sweep-plans.sh"
g20_run msys-then-trailing-slash
case_end
case_begin "G20-mixed-then-trailing-slash" "bin/sweep-plans.sh"
g20_run mixed-then-trailing-slash
case_end
case_begin "G20-native-then-trailing-backslash" "bin/sweep-plans.sh"
g20_run native-then-trailing-backslash
case_end

case_begin "G19-G20-every-table-row-ran-once" "bin/sweep-plans/gate-artifact.js"
for n in "${G19_ORDER[@]}"; do check "G19 table row $n ran exactly once" "1" "${G19_RAN[$n]:-0}"; done
for n in "${G20_ORDER[@]}"; do check "G20 table row $n ran exactly once" "1" "${G20_RAN[$n]:-0}"; done
case_end

# G23: a plans dir whose path carries spaces and shell metacharacters survives both passes intact.
case_begin "G23-plans-dir-with-spaces-and-metachars" "bin/sweep-plans.sh"
reset_gate
P="$T_ROOT/g23 plans \$HOME ;&'(x)"
mkdir -p "$P"; mk_old "$P" "${GA[@]}" "${GB[@]}" "$RAW_A"; P="$(cd "$P" && pwd)"
pass1 "$P"
check "G23 pass 1 exits 0" "0" "$RC"
check "G23 the artifact records the plans dir verbatim" "# plans-dir $(np "$P")" "$(sed -n 3p "$GATE_FILE" 2>/dev/null | tr -d '\r')"
expect_gone "G23 pass 1 removes the old non-plan $RAW_A" "$P/$RAW_A"
pass2 "$P" "$GID" "$(approve_file "$A")"
check "G23 pass 2 exits 0" "0" "$RC"
lacks_line "G23 pass 2 prints no gate ERROR" "$ERR" "^ERROR: sweep-plans:"
for n in "${GA[@]}"; do expect_gone "G23 approved A: $n is removed" "$P/$n"; done
expect_all_present "G23 unapproved B" "$P" "${GB[@]}"
expect_gone "G23 the gate artifact is consumed" "$GATE_FILE"
case_end

# G21: a gated pass 2 whose plans dir no longer exists is a verification failure, not a no-op.
case_begin "G21-pass2-missing-plans-dir" "bin/sweep-plans.sh"
reset_gate
P="$(new_dir g21)"; mk_old "$P" "${GA[@]}"
pass1 "$P"
check "G21 pass 1 exits 0" "0" "$RC"
expect_present "G21 precondition: pass 1 wrote the gate artifact" "$GATE_FILE"
pass2 "$T_ROOT/g21-no-such-plans-dir" "$GID" "$(approve_file "$A")"
check "G21 pass 2 against a missing plans dir exits 2" "2" "$RC"
check "G21 pass 2 prints exactly the gate ERROR line on stderr" "$GATE_ERR_LINE" "$ERR"
expect_present "G21 the gate artifact is not consumed" "$GATE_FILE"
expect_all_present "G21 the gated plans dir" "$P" "${GA[@]}"
case_end

# ── G22: the gate binds the physical plans dir (symlinks resolved) ───────────
# g22_run <name> <retarget: yes = point the link at B between passes; no = positive control>.
# mk_link <target> <link> — a real symlink or rc 1 (MSYS may silently copy instead of linking).
mk_link() {
  MSYS=winsymlinks:nativestrict ln -s "$1" "$2" 2>/dev/null || return 1
  [[ -L "$2" ]] || return 1
  printf 'p\n' > "$2/.g22-probe" 2>/dev/null || return 1
  [[ -f "$1/.g22-probe" ]] || return 1
  rm -f "$1/.g22-probe"
}
g22_run() {
  local name="$1" retarget="$2" base pa pb link n
  base="$T_ROOT/g22-$name"; pa="$base/A"; pb="$base/B"; link="$base/L"
  mkdir -p "$pa" "$pb"
  for n in "${GA[@]}" "$RAW_A"; do
    printf 'x\n' > "$pa/$n"; backdate_days 60 "$pa/$n"
    printf 'x\n' > "$pb/$n"; touch -r "$pa/$n" "$pb/$n"
  done
  if ! mk_link "$pa" "$link"; then
    skip "G22 $name (no real directory symlink on this host: ln -s copies or is refused)"; return
  fi
  reset_gate
  pass1 "$link"
  check "G22 $name pass 1 through L -> A exits 0" "0" "$RC"
  has_line "G22 $name pass 1 through L lists session A in the gate block" "$OUT" "^$A$TAB"
  if [[ ! "$GID" =~ ^[0-9a-f]{32}$ ]]; then fail "G22 $name precondition: pass 1 printed a gate id" "got=$GID"; return; fi
  # Pass 1 runs in apply mode, so the old non-plan RAW_A in A is deleted by default.
  expect_gone "G22 $name pass 1 removes A's old non-plan $RAW_A" "$pa/$RAW_A"
  if [[ "$retarget" == yes ]]; then
    rm -f "$link"
    if ! mk_link "$pb" "$link"; then fail "G22 $name precondition: L retargeted to B" "ln -s failed"; return; fi
    pass "G22 $name precondition: L retargeted to B"
  fi
  pass2 "$link" "$GID" "$(approve_file "$A")"
  if [[ "$retarget" == yes ]]; then
    check "G22 $name pass 2 through L -> B exits 2" "2" "$RC"
    check "G22 $name prints exactly the gate ERROR line on stderr" "$GATE_ERR_LINE" "$ERR"
    expect_all_present "G22 $name A" "$pa" "${GA[@]}"
    expect_all_present "G22 $name B" "$pb" "${GA[@]}" "$RAW_A"
  else
    check "G22 $name pass 2 through L -> A exits 0" "0" "$RC"
    lacks_line "G22 $name pass 2 prints no gate ERROR" "$ERR" "^ERROR: sweep-plans:"
    for n in "${GA[@]}"; do expect_gone "G22 $name approved A: $n is removed" "$pa/$n"; done
  fi
}

case_begin "G22-symlink-retargeted-between-passes" "bin/sweep-plans.sh"
g22_run symlink-retargeted-between-passes yes
case_end
case_begin "G22-symlink-unchanged-positive-control" "bin/sweep-plans.sh"
g22_run symlink-unchanged-positive-control no
case_end
