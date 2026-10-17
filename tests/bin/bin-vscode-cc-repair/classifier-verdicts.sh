# Part of tests/bin/bin-vscode-cc-repair.sh (sourced, not standalone).
# Tests: bin/vscode-cc-repair
# Tags: bin, vscode, extension-patch, scope:common, pwsh-not-required, TL2
# C1 — every classifier verdict (incl. `unknown`) via exported classifyValue/classify, and
# the delimiter rule: `!1`/`!0` before alnum/`_`/`$` is no literal; before other punctuation it is.

# classifyValue receives the text immediately following `includeWorktrees:`.
# <SP> in the table stands for a literal leading space (whitespace is stripped from
# the table columns, so the space cannot be written inline).
run_c1_values() {
  local name rest want
  while IFS='|' read -r name rest want; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    rest="${rest//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    rest="${rest//<SP>/ }"
    REST="$rest" node_m 'const m=require("'"$REQUIRE_PATH"'");
console.log("V="+m.classifyValue(process.env.REST));'
    check "$name: classifyValue([$rest])" "V=$want" "$NODE_OUT"
  done <<'TABLE'
C1-v01 | !1}        | falsy
C1-v02 | !1,        | falsy
C1-v03 | !1)        | falsy
C1-v04 | !1;        | falsy
C1-v05 | !1<SP>     | falsy
C1-v06 | !0}        | truthy
C1-v07 | !0,        | truthy
C1-v08 | !0)        | truthy
C1-v09 | !0;        | truthy
C1-v10 | !10        | unknown
C1-v11 | !1x        | unknown
C1-v12 | !1_        | unknown
C1-v13 | !1$        | unknown
C1-v14 | !00        | unknown
C1-v15 | !0x        | unknown
C1-v16 | !0_        | unknown
C1-v17 | !0$        | unknown
C1-v18 | true}      | unsupported
C1-v19 | <SP>true}  | unsupported
C1-v20 | false}     | unsupported
C1-v21 | <SP>false} | unsupported
C1-v22 | truely}    | dynamic
C1-v23 | falsey}    | dynamic
C1-v24 | i}         | dynamic
C1-v25 | _x}        | dynamic
C1-v26 | $y}        | dynamic
C1-v27 | 0}         | unknown
C1-v28 | [0]}       | unknown
C1-v29 | !!x}       | unknown
TABLE
}

# classify() decision order, exercised on whole-file bodies.
run_c1_states() {
  local name bodyvar want
  while IFS='|' read -r name bodyvar want; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    bodyvar="${bodyvar//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    BODY="${!bodyvar}" node_m 'const m=require("'"$REQUIRE_PATH"'");
console.log("S="+m.classify(process.env.BODY).state);'
    check "$name: classify state" "S=$want" "$NODE_OUT"
  done <<'TABLE'
C1-s01-real-falsy      | BODY_FALSY            | unpatched
C1-s02-real-truthy     | BODY_TRUTHY           | already
C1-s03-two-truthy      | BODY_TWO_TRUTHY       | refused
C1-s04-two-falsy       | BODY_TWO_FALSY        | refused
C1-s05-mixed           | BODY_MIXED            | refused
C1-s06-unsupported     | BODY_UNSUPPORTED      | refused
C1-s07-unsupported-bare| BODY_UNSUPPORTED_TRUE | refused
C1-s08-unknown         | BODY_UNKNOWN          | refused
C1-s09-absent          | BODY_ABSENT           | absent
C1-s10-dynamic-only    | BODY_DYNAMIC          | absent
C1-s11-paren-in-anchor | BODY_PAREN_FALSY      | refused
C1-s12-semi-no-anchor  | BODY_SEMI_FALSY       | refused
C1-s13-bad-syntax      | BODY_BAD_SYNTAX       | unpatched
C1-a01-v2130           | BODY_V2130            | unpatched
C1-a02-v2130-rev       | BODY_V2130_REV        | unpatched
C1-a03-v2130-patched   | BODY_V2130_PATCHED    | already
C1-a04-noanchor-falsy  | BODY_NOANCHOR_FALSY   | refused
C1-a05-noanchor-truthy | BODY_NOANCHOR_TRUTHY  | refused
C1-a06-two-anchors     | BODY_TWO_ANCHORS      | refused
C1-a07-anchor-two-keys | BODY_ANCHOR_TWO_KEYS  | refused
C1-a08-anchor-dynamic  | BODY_ANCHOR_DYNAMIC   | refused
C1-a09-anchor-unknown  | BODY_ANCHOR_UNKNOWN   | refused
C1-a10-anchor-true     | BODY_ANCHOR_TRUE      | refused
C1-a11-anchor-false    | BODY_ANCHOR_FALSE     | refused
C1-a12-outside-unknown | BODY_OUTSIDE_UNKNOWN  | refused
C1-a13-outside-true    | BODY_OUTSIDE_TRUE     | refused
C1-a14-outside-false   | BODY_OUTSIDE_FALSE    | refused
C1-a15-anchor-keyless  | BODY_ANCHOR_KEYLESS   | refused
C1-a16-anchor-nokey    | BODY_ANCHOR_NOKEY     | absent
C1-a17-nested-before   | BODY_ANCHOR_NESTED_BEFORE | refused
C1-a18-nested-after    | BODY_ANCHOR_NESTED_AFTER  | refused
C1-a19-nested-nokey    | BODY_ANCHOR_NESTED_NOKEY  | unpatched
C1-a20-nested-patched  | BODY_ANCHOR_NESTED_NOKEY_PATCHED | already
C1-a21-nested-only        | BODY_ANCHOR_NESTED_ONLY        | refused
C1-a22-nested-only-truthy | BODY_ANCHOR_NESTED_ONLY_TRUTHY | refused
C1-a23-array-nested       | BODY_ANCHOR_ARRAY_NESTED       | refused
C1-a24-str-sibling        | BODY_ANCHOR_STR_SIBLING        | refused
C1-a25-str-close          | BODY_ANCHOR_STR_CLOSE          | unpatched
C1-a26-str-close-patched  | BODY_ANCHOR_STR_CLOSE_PATCHED  | already
C1-a27-esc-dq             | BODY_ANCHOR_ESC_DQ             | unpatched
C1-a28-esc-sq             | BODY_ANCHOR_ESC_SQ             | unpatched
C1-a29-key-in-str         | BODY_ANCHOR_KEY_IN_STR         | refused
C1-a30-template           | BODY_ANCHOR_TEMPLATE           | refused
C1-a31-regex              | BODY_ANCHOR_REGEX              | refused
C1-a32-unclosed           | BODY_ANCHOR_UNCLOSED           | refused
C1-a33-semi-in-anchor     | BODY_SEMI_ANCHORED             | refused
C1-a34-anchor-in-dq        | BODY_ANCHOR_IN_DQ              | refused
C1-a35-anchor-in-dq-truthy | BODY_ANCHOR_IN_DQ_TRUTHY       | refused
C1-a36-anchor-in-sq        | BODY_ANCHOR_IN_SQ              | refused
C1-a37-anchor-in-comment   | BODY_ANCHOR_IN_COMMENT         | refused
C1-a38-after-rbrace        | BODY_ANCHOR_AFTER_RBRACE       | unpatched
C1-a39-after-comma         | BODY_ANCHOR_AFTER_COMMA        | unpatched
C1-a40-after-semi          | BODY_ANCHOR_AFTER_SEMI         | unpatched
C1-a41-after-lbrace        | BODY_ANCHOR_AFTER_LBRACE       | unpatched
C1-a42-at-offset0          | BODY_ANCHOR_AT_OFFSET0         | unpatched
C1-m01-falsy-unknown      | BODY_FALSY_UNKNOWN       | refused
C1-m02-falsy-unsupported  | BODY_FALSY_UNSUPPORTED   | refused
C1-m03-truthy-unknown     | BODY_TRUTHY_UNKNOWN      | refused
C1-m04-truthy-unsupported | BODY_TRUTHY_UNSUPPORTED  | refused
C10-c01-key-at-eof        | BODY_KEY_AT_EOF          | refused
C10-c02-empty-file        | BODY_EMPTY               | absent
TABLE
}

# Mixed-site precedence, at the counts level. `state` alone cannot separate the
# `nUnsupported + nUnknown > 0` branch from the `nLiteral >= 2` branch — both say
# `refused`. Pinning nLiteral === 1 proves these bodies really exercise the FIRST test
# in the decision order: were that test moved after the nLiteral tests, m05/m06 would
# fall through to `unpatched` (and PATCH a file holding a site the tool cannot read)
# and m07/m08 to `already` (and silently walk past it).
run_c1_mixed_counts() {
  local name bodyvar want
  while IFS='|' read -r name bodyvar want; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    bodyvar="${bodyvar//[[:space:]]/}"
    want="$(printf '%s' "$want" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    BODY="${!bodyvar}" node_m 'const m=require("'"$REQUIRE_PATH"'");
const c=m.classify(process.env.BODY);const n=c.counts;
console.log("S="+c.state+" L="+n.nLiteral+" F="+n.nFalsy+" T="+n.nTruthy+" P="+n.nUnsupported+" U="+n.nUnknown+" K="+n.nKey);'
    check "$name: one literal plus one unrecognised site still refuses" "$want" "$NODE_OUT"
  done <<'TABLE'
C1-m05-falsy-unknown      | BODY_FALSY_UNKNOWN      | S=refused L=1 F=1 T=0 P=0 U=1 K=2
C1-m06-falsy-unsupported  | BODY_FALSY_UNSUPPORTED  | S=refused L=1 F=1 T=0 P=1 U=0 K=2
C1-m07-truthy-unknown     | BODY_TRUTHY_UNKNOWN     | S=refused L=1 F=0 T=1 P=0 U=1 K=2
C1-m08-truthy-unsupported | BODY_TRUTHY_UNSUPPORTED | S=refused L=1 F=0 T=1 P=1 U=0 K=2
TABLE
}

# C10 — the key is the final token in the file, so classifyValue receives the empty
# string. Every anchored shape misses it, so the fall-through verdict is `unknown`,
# which refuses. The zero-byte bundle has no key at all and is the `absent` counterpart.
run_c10_classifier() {
  REST='' node_m 'const m=require("'"$REQUIRE_PATH"'");
console.log("V="+m.classifyValue(process.env.REST));'
  check "C10-c03: classifyValue of an empty rest falls through to unknown" \
    "V=unknown" "$NODE_OUT"

  BODY="$BODY_KEY_AT_EOF" node_m 'const m=require("'"$REQUIRE_PATH"'");
const c=m.classify(process.env.BODY);const n=c.counts;
console.log("S="+c.state+" L="+n.nLiteral+" U="+n.nUnknown+" K="+n.nKey);'
  check "C10-c04: key at EOF with no value counts one unknown site and refuses" \
    "S=refused L=0 U=1 K=1" "$NODE_OUT"

  BODY="$BODY_EMPTY" node_m 'const m=require("'"$REQUIRE_PATH"'");
const c=m.classify(process.env.BODY);const n=c.counts;
console.log("S="+c.state+" L="+n.nLiteral+" U="+n.nUnknown+" K="+n.nKey);'
  check "C10-c05: a zero-byte bundle is absent, not refused" \
    "S=absent L=0 U=0 K=0" "$NODE_OUT"
}

# The unsupported/unknown refusal must sit BEFORE the nLiteral === 0 test: `!10`
# yields zero literals, so an ordering slip would report `absent` (exit 0) instead
# of `refused` (exit 1) and silently walk past an unrecognised call site.
run_c1_counts() {
  BODY="$BODY_UNKNOWN" node_m 'const m=require("'"$REQUIRE_PATH"'");
const r=m.classify(process.env.BODY);
console.log("S="+r.state+" L="+r.counts.nLiteral+" U="+r.counts.nUnknown+" K="+r.counts.nKey);'
  check "C1-c01: bang-1-0 refuses despite zero literals (order before nLiteral===0)" \
    "S=refused L=0 U=1 K=1" "$NODE_OUT"

  BODY="$BODY_DYNAMIC" node_m 'const m=require("'"$REQUIRE_PATH"'");
const r=m.classify(process.env.BODY);
console.log("S="+r.state+" L="+r.counts.nLiteral+" D="+r.counts.nDynamic+" K="+r.counts.nKey);'
  check "C1-c02: destructuring-only site counts the key but no literal" \
    "S=absent L=0 D=1 K=1" "$NODE_OUT"

  BODY="$BODY_FALSY" node_m 'const m=require("'"$REQUIRE_PATH"'");
const r=m.classify(process.env.BODY);
console.log("K="+r.counts.nKey+" L="+r.counts.nLiteral+" F="+r.counts.nFalsy+" D="+r.counts.nDynamic);'
  check "C1-c03: real-bundle shape counts 2 keys but only 1 literal" \
    "K=2 L=1 F=1 D=1" "$NODE_OUT"
}

# siteOffset must address the start of the KEY, not the start of the literal —
# the splice length depends on it. A parenthesised (ternary) key is nested under the
# default method since #2683, so its splice offset is proven under the legacy method.
run_c1_offset() {
  local name bodyvar method
  while IFS='|' read -r name bodyvar method; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    bodyvar="${bodyvar//[[:space:]]/}"; method="${method//[[:space:]]/}"
    BODY="${!bodyvar}" METHOD="$method" node_m 'const m=require("'"$REQUIRE_PATH"'");
const r=m.classify(process.env.BODY,{method:process.env.METHOD});const s=process.env.BODY.slice(r.siteOffset);
console.log("OFF="+(s.indexOf("includeWorktrees:!1")===0?"key":(s.indexOf("!1")===0?"literal-only":"other:"+r.siteOffset)));'
    check "$name: siteOffset starts the includeWorktrees:!1 site" "OFF=key" "$NODE_OUT"
  done <<'TABLE'
C1-o01-object   | BODY_FALSY       | anchor
C1-o02-ternary  | BODY_PAREN_FALSY | legacy
TABLE
}

# #2683 — with a second `includeWorktrees:!1` outside the anchor, siteOffset must land on
# the anchor-internal key whichever comes first in the file.
run_c1_anchor_offset() {
  local name bodyvar
  while IFS='|' read -r name bodyvar; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    bodyvar="${bodyvar//[[:space:]]/}"
    BODY="${!bodyvar}" node_m 'const m=require("'"$REQUIRE_PATH"'");
const b=process.env.BODY;const r=m.classify(b);
const a=b.indexOf("sessionListOptions(){return{");const want=b.indexOf("includeWorktrees:!1",a);
console.log("OFF="+(r.siteOffset===want?"anchor":"other:"+r.siteOffset+"/"+want));'
    check "$name: siteOffset is the anchor-internal site" "OFF=anchor" "$NODE_OUT"
  done <<'TABLE'
C1-o03-v2130-anchor-first   | BODY_V2130
C1-o04-v2130-outside-first  | BODY_V2130_REV
C1-o05-str-close            | BODY_ANCHOR_STR_CLOSE
C1-o06-esc-dq               | BODY_ANCHOR_ESC_DQ
C1-o07-esc-sq               | BODY_ANCHOR_ESC_SQ
TABLE
}

# #2683 — anchor boundary rule: a lone anchor preceded by anything but `{` `}` `,` `;`
# refuses as ambiguous-anchor; the legacy method keeps its verdict but reports the same value.
run_c1_anchor_boundary() {
  local name bodyvar method want
  while IFS='|' read -r name bodyvar method want; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    bodyvar="${bodyvar//[[:space:]]/}"; method="${method//[[:space:]]/}"
    want="$(printf '%s' "$want" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    BODY="${!bodyvar}" METHOD="$method" node_m 'const m=require("'"$REQUIRE_PATH"'");
const r=m.classify(process.env.BODY,{method:process.env.METHOD});
console.log("S="+r.state+" R="+(r.reason||"-")+" A="+r.counts.nAnchor+" V="+r.counts.anchorValue);'
    check "$name: boundary verdict" "$want" "$NODE_OUT"
  done <<'TABLE'
C1-b01-in-dq             | BODY_ANCHOR_IN_DQ        | anchor | S=refused R=ambiguous-anchor A=1 V=ambiguous
C1-b02-in-dq-truthy      | BODY_ANCHOR_IN_DQ_TRUTHY | anchor | S=refused R=ambiguous-anchor A=1 V=ambiguous
C1-b03-in-sq             | BODY_ANCHOR_IN_SQ        | anchor | S=refused R=ambiguous-anchor A=1 V=ambiguous
C1-b04-in-comment        | BODY_ANCHOR_IN_COMMENT   | anchor | S=refused R=ambiguous-anchor A=1 V=ambiguous
C1-b05-after-rbrace      | BODY_ANCHOR_AFTER_RBRACE | anchor | S=unpatched R=- A=1 V=falsy
C1-b06-at-offset0        | BODY_ANCHOR_AT_OFFSET0   | anchor | S=unpatched R=- A=1 V=falsy
C1-b07-legacy-in-dq      | BODY_ANCHOR_IN_DQ        | legacy | S=unpatched R=- A=1 V=ambiguous
C1-b08-legacy-in-dq-tru  | BODY_ANCHOR_IN_DQ_TRUTHY | legacy | S=already R=- A=1 V=ambiguous
TABLE
}

run_c1_values
run_c1_states
run_c1_anchor_boundary
run_c1_mixed_counts
run_c10_classifier
run_c1_counts
run_c1_offset
run_c1_anchor_offset
