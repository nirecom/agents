# The fixture rows of the table-match check and the message of each verdict key
# (#2561). Sourced by tests/bin/feature-2561-root-names-table-match.sh, which defines
# the assembled spellings first. Defines functions only. The "rule" rows run under
# EXC_SOURCE: a carrier whose source path spells the name in kebab case and whose
# files are hooks/path-user.js and hooks/path-other.js.

# msg_of <key> — the message of a reported row: a name outside the rule (by its
# initials), a carrier spelling outside its files, or a file no rule matches.
msg_of() {
  case "$1" in
    scr) printf '%s is not allowed by the rule of this file' "$N_SCR" ;;
    amr) printf '%s is not allowed by the rule of this file' "$N_AMR" ;;
    tmr) printf '%s is not allowed by the rule of this file' "$N_TMR" ;;
    tcr) printf '%s is not allowed by the rule of this file' "$N_TCR" ;;
    spelling) printf 'belongs to the files its carrier lists' ;;
    norule) printf 'no classification rule matches this file' ;;
    *) printf 'no-such-message-key' ;;
  esac
}

# The fixture rows: name | group | verdict | path | fixture line (text, never run).
# group "rule" = a file against its classification rule; group "kinds" = a carrier file
# list against a carrier of another kind. verdict: clean = the check prints nothing for
# the path; any other word is a msg_of key — line 1 is reported with that message
# ("norule": the file is). The heredoc is unquoted so the assembled names expand.
match_rows() {
  cat <<TABLE
ok-bin             | rule  | clean    | bin/ok.sh                      | echo "$V_SCR"
ok-earlier-rule    | rule  | clean    | bin/special/two.sh             | echo "$V_SCR \$$N_TMR"
ok-hooks           | rule  | clean    | hooks/ok.js                    | use($N_SCR);
ok-skill-script    | rule  | clean    | skills/s/scripts/ok.sh         | echo "$V_SCR"
ok-skill-prose     | rule  | clean    | skills/s/SKILL.md              | Run the tool under $V_AMR.
ok-docs            | rule  | clean    | docs/ok.md                     | Set $N_AMR in the profile.
ok-tests-all       | rule  | clean    | tests/ok.sh                    | echo "$V_SCR $V_AMR \$$N_TMR \$$N_TCR"
ok-tests-spellings | rule  | clean    | tests/ok-spellings.js          | use($CAMEL_TMR, "--$KEBAB_TCR", "$SNAKE_TMR");
ok-no-name         | rule  | clean    | plain/none.txt                 | no root name here
ok-named-file      | rule  | clean    | bin/named.js                   | read($N_AMR);
ok-prop-source     | rule  | clean    | bin/carrier-src.js             | $C_PROP = $N_SCR;
ok-prop-user       | rule  | clean    | bin/carrier-user.js            | use($C_PROP);
ok-key-source      | rule  | clean    | hooks/key-src.js               | const KEY = "$C_KEY";
ok-key-user        | rule  | clean    | hooks/key-user.js              | use(payload.$C_KEY);
ok-key-doc         | rule  | clean    | docs/key.md                    | The payload key is $C_KEY.
ok-fn-source       | rule  | clean    | hooks/fn-src.js                | function $C_FN() { return $N_SCR; }
ok-fn-user         | rule  | clean    | hooks/fn-user.js               | use($C_FN());
ok-tests-scr       | rule  | clean    | tests/ok-scr-spellings.js      | use($CAMEL_SCR, "--$KEBAB_SCR", "$LOWER_SCR");
ok-derived-script  | rule  | clean    | docs/derived.md                | Keep FAKE_$N_SCR and ${N_SCR}_OLD apart.
ok-derived-agents  | rule  | clean    | plain/derived.txt              | MY_$N_AMR and ${N_AMR}2 are other names
ok-source-path     | rule  | clean    | hooks/path-user.js             | const r = require("./lib/$KEBAB_SCR");
bad-agents-in-bin  | rule  | amr      | bin/bad-agents.sh              | echo "$V_AMR"
bad-target-in-bin  | rule  | tcr      | bin/bad-target.js              | use($N_TCR);
bad-third-name     | rule  | tcr      | bin/special/bad-three.sh       | echo "\$$N_TCR"
bad-camel          | rule  | tmr      | hooks/bad-camel.js             | use($CAMEL_TMR);
bad-kebab          | rule  | tcr      | hooks/bad-kebab.js             | args.push("--$KEBAB_TCR");
bad-skill-script   | rule  | amr      | skills/s/scripts/bad-agents.sh | echo "$V_AMR"
bad-skill-prose    | rule  | scr      | skills/s/bad-script.md         | Run under $V_SCR.
bad-docs           | rule  | scr      | docs/bad-script.md             | Read $N_SCR here.
bad-snake          | rule  | tmr      | docs/bad-snake.md              | The $SNAKE_TMR field.
bad-plain          | rule  | amr      | plain/bad-any.txt              | mentions $N_AMR
bad-named-suffix   | rule  | amr      | bin/named.js.bak               | read($N_AMR);
bad-carrier-prop   | rule  | spelling | bin/bad-carrier-prop.js        | use($C_PROP);
bad-carrier-key    | rule  | spelling | hooks/bad-carrier-key.js       | use(payload.$C_KEY);
bad-carrier-fn     | rule  | spelling | hooks/bad-carrier-fn.js        | use($C_FN());
bad-kebab-script   | rule  | spelling | bin/bad-kebab-script.js        | args.push("--$KEBAB_SCR");
bad-lower-script   | rule  | spelling | bin/bad-lower.sh               | $LOWER_SCR=x
bad-listed-suffix  | rule  | spelling | bin/carrier-user.js.other      | use(payload.$C_KEY);
bad-source-path    | rule  | spelling | hooks/bad-path-user.js         | const r = require("./lib/$KEBAB_SCR");
bad-source-other   | rule  | spelling | hooks/path-other.js            | use(r.$LOWER_SCR);
bad-unmatched      | rule  | norule   | unmatched/no-rule.txt          | no root name here
bad-other-repo     | rule  | norule   | dot/only-dotfiles.sh           | echo "$V_AMR"
# The carrier files list what a file may add; a carrier of another kind stays out.
kind-key-in-prop   | kinds | spelling | bin/carrier-listed.js          | use(payload.$C_KEY);
kind-prop-in-fn    | kinds | spelling | hooks/fn-user.js               | use($C_PROP);
kind-own-carrier   | kinds | clean    | bin/carrier-user.js            | use($C_PROP);
TABLE
}
