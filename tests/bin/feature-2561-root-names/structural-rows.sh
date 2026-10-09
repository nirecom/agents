# Fixture rows of the structural check (#2561). Sourced by
# tests/bin/feature-2561-root-names-structural.sh, which defines the assembled
# spellings (MODIFIED_PARAM, REAL_ROOT_CALL) first. Defines functions only.

# msg_of <key> — the part of the message a reported row must carry.
msg_of() {
  case "$1" in
    sub) printf 'joined to a code directory' ;;
    exported) printf 'but it is exported' ;;
    handed) printf 'but it is handed to another command' ;;
    env) printf 'but it is put into an environment' ;;
    psenv) printf 'but it is put into the environment' ;;
    param) printf 'a function takes the checkout root as a parameter' ;;
    prop) printf 'only the source of this carrier writes the property' ;;
    fn) printf 'only the source of this carrier defines the function' ;;
    blind) printf 'must compare it with its own checkout root' ;;
    decoy) printf 'leaving the decoy needs a named exception' ;;
    *) printf 'no-such-message-key' ;;
  esac
}

# The fixture rows: name | rule | verdict | path | fixture line (text, never run).
# verdict: clean = the check prints nothing for the path; clean-alone = clean, seeded
# only into the rule's accepted tree (the path also has a reported row); any other
# word is a msg_of key: line 1 is reported with that message ("blind": the file is).
# The heredoc is unquoted so the assembled names expand; \$ \` and \\ stay literal.
structural_rows() {
  cat <<TABLE
# subpath: no code path below the main root in executable code.
a-bin            | subpath   | sub         | bin/a-bin.sh                 | bash "$V_AMR/bin/tool"
a-exact          | subpath   | sub         | bin/a-exact.sh               | ls "$V_AMR/bin"
a-hooks          | subpath   | sub         | hooks/a-hooks.js             | require(\`\${process.env.$N_AMR}/hooks/x.js\`);
a-join           | subpath   | sub         | hooks/a-join.js              | require(path.join(process.env.$N_AMR, "hooks", "x.js"));
a-plus           | subpath   | sub         | hooks/a-plus.js              | require(process.env.$N_AMR + "/hooks/x.js");
a-powershell     | subpath   | sub         | bin/a-ps.ps1                 | & "\$env:$N_AMR\\bin\\tool.ps1"
a-skill-script   | subpath   | sub         | skills/s/scripts/a-skills.sh | cat "\${$N_AMR}/skills/x/SKILL.md"
a-test           | subpath   | sub         | tests/a-test.sh              | node "$V_AMR/hooks/x.js"
a-env-file       | subpath   | clean       | bin/a-env.sh                 | cat "$V_AMR/.env"
a-rules-file     | subpath   | clean       | bin/a-rules.sh               | cat "$V_AMR/rules/x.md"
a-longer-dir     | subpath   | clean       | bin/a-longer-dir.sh          | ls "$V_AMR/bin-extra" "$V_AMR/binary"
a-longer-name    | subpath   | clean       | bin/a-longer-name.sh         | ls "\$MY_$N_AMR/bin"
a-sh-comment     | subpath   | clean       | bin/a-comment.sh             | true # bash "$V_AMR/bin/tool"
a-js-comment     | subpath   | clean       | hooks/a-comment.js           | use(); // require(process.env.$N_AMR + "/hooks/x.js");
a-js-block       | subpath   | clean       | hooks/a-block.js             | /* path.join(process.env.$N_AMR, "hooks") */ use();
a-ps-comment     | subpath   | clean       | bin/a-comment.ps1            | <# & "\$env:$N_AMR\\bin\\tool.ps1" #> Write-Output ok
a-skill-prose    | subpath   | clean       | skills/s/SKILL.md            | Run \`$V_AMR/bin/tool\` first.
a-doc-prose      | subpath   | clean       | docs/a.md                    | Run $V_AMR/bin/tool first.
a-excepted       | subpath   | clean       | bin/a-excepted.sh            | bash "$V_AMR/bin/tool"
a-own-checkout   | subpath   | clean       | bin/a-own.sh                 | bash "$V_SCR/bin/tool"
a-out-install    | subpath   | clean       | install/a-install.sh         | bash "$V_AMR/bin/tool"
a-out-skill-lib  | subpath   | clean       | skills/s/lib/a-lib.sh        | bash "$V_AMR/bin/tool"
a-out-root-file  | subpath   | clean       | a-root.js                    | require(process.env.$N_AMR + "/hooks/x.js");
# handover: the checkout root never crosses a process boundary.
b-export         | handover  | exported    | bin/b-export.sh              | export $N_SCR
b-export-assign  | handover  | exported    | bin/b-export-assign.sh       | export $N_SCR=/x
b-declare-x      | handover  | exported    | bin/b-declare.sh             | declare -x $N_SCR=/x
b-typeset-x      | handover  | exported    | bin/b-typeset.sh             | typeset -rx $N_SCR=/x
b-test-export    | handover  | exported    | tests/b-test-export.sh       | export $N_SCR
b-prefix         | handover  | handed      | bin/b-prefix.sh              | $N_SCR=/x node tool.js
b-env-command    | handover  | handed      | bin/b-env-cmd.sh             | env $N_SCR=/x node tool.js
b-env-key        | handover  | env         | hooks/b-envkey.js            | spawn("node", [], { env: { ...process.env, $N_SCR: root } });
b-env-assign     | handover  | env         | hooks/b-envassign.js         | process.env.$N_SCR = root;
b-env-bracket    | handover  | env         | hooks/b-bracket.js           | process.env["$N_SCR"] = root;
b-carrier-to-env | handover  | env         | bin/carrier-user.js          | process.env.$N_SCR = $C_PROP;
b-powershell     | handover  | psenv       | bin/b-env.ps1                | \$env:$N_SCR = \$root
b-node-e         | handover  | clean       | bin/b-node-e.sh              | $N_SCR="$V_SCR" node -e 'run()'
b-bash-c         | handover  | clean       | bin/b-bash-c.sh              | $N_SCR="$V_SCR" bash -c 'run'
b-plain-use      | handover  | clean       | bin/b-plain.sh               | echo "$V_SCR/bin/tool"
b-declare-plain  | handover  | clean       | bin/b-declare-plain.sh       | declare -r $N_SCR=/x
b-argument       | handover  | clean       | hooks/b-arg.js               | spawn("node", [tool, $N_SCR]);
b-target-export  | handover  | clean       | bin/b-target.sh              | export $N_TMR=/x
b-sh-comment     | handover  | clean       | bin/b-comment.sh             | true # export $N_SCR
b-sh-string      | handover  | clean       | bin/b-string.sh              | echo "export $N_SCR=/x"
b-js-comment     | handover  | clean       | hooks/b-comment.js           | use(); // process.env.$N_SCR = root;
b-js-compare     | handover  | clean       | hooks/b-compare.js           | if (process.env.$N_SCR === root) use();
b-ps-comment     | handover  | clean       | bin/b-comment.ps1            | Write-Output ok # \$env:$N_SCR = \$root
b-ps-read        | handover  | clean       | bin/b-read.ps1               | Write-Output \$env:$N_SCR
# parameter: a non-test function never takes the checkout root as a parameter.
c-function       | parameter | param       | bin/c-fn.js                  | function probe($CAMEL_SCR, key) {}
c-arrow          | parameter | param       | hooks/c-arrow.js             | const f = ($MODIFIED_PARAM) => 1;
c-bare-arrow     | parameter | param       | hooks/c-bare.js              | const f = $CAMEL_SCR => 1;
c-method         | parameter | param       | bin/c-method.js              | load($CAMEL_SCR) {
c-upper          | parameter | param       | bin/c-upper.js               | function probe($N_SCR) {}
c-default        | parameter | param       | bin/c-default.js             | function probe($CAMEL_SCR = here) {}
c-carrier-file   | parameter | param       | bin/carrier-listed.js        | function g($CAMEL_SCR) { return $C_PROP; }
c-test-function  | parameter | clean       | tests/c-test.js              | function probe($CAMEL_SCR) {}
c-call-argument  | parameter | clean       | bin/c-call.js                | probe($N_SCR, other);
c-other-name     | parameter | clean       | bin/c-other.js               | function probe(checkoutRoot) {}
c-default-value  | parameter | clean       | bin/c-default-value.js       | function probe(dir = $CAMEL_SCR) {}
c-condition      | parameter | clean       | bin/c-if.js                  | if ($CAMEL_SCR) { use(); }
c-js-comment     | parameter | clean       | bin/c-comment.js             | use(); // function probe($CAMEL_SCR) {}
c-js-string      | parameter | clean       | bin/c-string.js              | log("function probe($CAMEL_SCR) {}");
# carrier: only the source of a carrier writes it; a test file is free to (each d-test-*
# row pairs with the reported row of the same line). Its clean rows go into every tree.
d-prop-write     | carrier   | prop        | bin/carrier-listed.js        | $C_PROP = other;
d-literal-write  | carrier   | prop        | bin/carrier-user.js          | const anchors = { $CAMEL_SCR: other };
d-fn-redefine    | carrier   | fn          | hooks/fn-user.js             | function $C_FN() { return 1; }
d-fn-const       | carrier   | fn          | hooks/d-fn-const.js          | const $C_FN = () => 1;
d-key-blind      | carrier   | blind       | hooks/key-blind.js           | use(payload.$C_KEY);
d-prop-source    | carrier   | clean       | bin/carrier-src.js           | $C_PROP = $N_SCR;
d-fn-source      | carrier   | clean       | hooks/fn-src.js              | function $C_FN() { return $N_SCR; }
d-key-source     | carrier   | clean       | hooks/key-src.js             | const KEY = "$C_KEY";
d-key-user       | carrier   | clean       | hooks/key-user.js            | use(payload.$C_KEY, $C_PROP);
d-destructure    | carrier   | clean       | bin/d-destructure.js         | const { $CAMEL_SCR: mine } = anchors;
d-fn-import      | carrier   | clean       | hooks/d-fn-import.js         | const { $C_FN } = require("./fn-src");
d-fn-require     | carrier   | clean       | hooks/d-fn-require.js        | const $C_FN = require("./fn-src").$C_FN;
d-js-comment     | carrier   | clean       | bin/d-comment.js             | use(); // $C_PROP = other;
d-test-prop      | carrier   | clean       | tests/d-test-prop.js         | $C_PROP = other;
d-test-literal   | carrier   | clean       | tests/d-test-literal.js      | const anchors = { $CAMEL_SCR: other };
d-test-fn        | carrier   | clean       | tests/d-test-fn.js           | function $C_FN() { return 1; }
d-test-fn-const  | carrier   | clean       | tests/d-test-fn-const.js     | const $C_FN = () => 1;
d-prop-reader    | carrier   | clean-alone | bin/carrier-user.js          | use($C_PROP);
d-prop-compare   | carrier   | clean-alone | bin/carrier-listed.js        | if ($C_PROP === other) use();
d-fn-caller      | carrier   | clean-alone | hooks/fn-user.js             | use($C_FN());
# real-root: only a named exception leaves the decoy.
e-call           | real-root | decoy       | tests/e-call.sh              | $REAL_ROOT_CALL
e-branch         | real-root | decoy       | tests/e-branch.sh            | if true; then $REAL_ROOT_CALL; fi
e-outside-tests  | real-root | decoy       | bin/e-bin.sh                 | $REAL_ROOT_CALL
e-excepted       | real-root | clean       | tests/e-allowed.sh           | $REAL_ROOT_CALL
e-other-call     | real-root | clean       | tests/e-other.sh             | root_decoy_enter
e-definition     | real-root | clean       | tests/e-def.sh               | $REAL_ROOT_CALL() { :; }
e-comment        | real-root | clean       | tests/e-comment.sh           | true # $REAL_ROOT_CALL
e-mention        | real-root | clean       | tests/e-mention.sh           | echo $REAL_ROOT_CALL
TABLE
}
