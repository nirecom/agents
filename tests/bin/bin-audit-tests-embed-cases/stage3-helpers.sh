# Tests: bin/lib/test-embed-cases/stage-apply.sh
# Tags: TL2, scope:common, audit-tests, embed-cases, stage-protocol, stage-3, fixture
# Sourced by the -apply / -harden entrypoints: stage-3 fixture helpers. Holds no cases.

# s3_plan <name>... — fresh repo with tests/bin/t-<name>.sh (header bin/<name>.sh) after
# stage 1 over all of them; sets S3_REPO and EC_WORKDIR. Stage 1 runs once per name set;
# each call copies that repo and workdir (same embed root). The worklist holds no repo path
# and each copy is a new repo no other case's retry row or ledger entry matches.
s3_plan() {
  local key="$*" tpl n root
  tpl="$EC_TMP/s3-template-${key// /-}"
  if [[ ! -d "$tpl" ]]; then
    S3_REPO="$(ec_make_repo)"
    for n in "$@"; do ec_add_test "$S3_REPO" "tests/bin/t-$n.sh" "bin/$n.sh"; done
    ec_commit "$S3_REPO" init
    ec_stage1 "$S3_REPO" "$AUDIT" --band-size 5
    mkdir -p "$tpl"
    printf '%s\n' "$S3_REPO" >"$tpl/repo"
    if [[ -n "$EC_WORKDIR" && -d "$EC_WORKDIR" ]]; then
      printf '%s\n' "${EC_WORKDIR%/*}" >"$tpl/root"
      mv "$EC_WORKDIR" "$tpl/workdir"
    fi
  fi
  S3_REPO="$(mktemp -d -p "$EC_TMP")"
  cp -Rp "$(<"$tpl/repo")/." "$S3_REPO/"
  EC_WORKDIR=""
  if [[ -d "$tpl/workdir" ]]; then
    root="$(<"$tpl/root")"
    EC_WORKDIR="$(mktemp -d -p "$root" s3copy.XXXXXX)"
    cp -Rp "$tpl/workdir/." "$EC_WORKDIR/"
  fi
}

# s3_good <name> — a verifier-passing output for tests/bin/t-<name>.sh.
s3_good() { ec_write_embedded "$(ec_item_output "tests/bin/t-$1.sh")" "bin/$1.sh" "bin/$1.sh"; }

# s3_hash <name> — current git hash-object of tests/bin/t-<name>.sh in S3_REPO.
s3_hash() { git -C "$S3_REPO" hash-object "tests/bin/t-$1.sh"; }

# s3_untouched <label> <name> <hash-before> — the original stayed byte-identical.
s3_untouched() { check_eq "$1 tests/bin/t-$2.sh is left as it was" "$3" "$(s3_hash "$2")"; }

grp_done stage3-helpers.sh
