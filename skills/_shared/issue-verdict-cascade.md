# Issue Verdict Cascade (SSOT)

起票候補に対する verdict 判定基準の唯一の定義。`/issue-create` のサーベイ用サブエージェントと
`bin/github-issues/review-survey-verdict-codex.sh` のレビュー段の**両方**がこの 1 ファイルを読む。
どちらの側にも本文を複製しない。

## 評価順序

**上から順に評価し、最初に該当した規則で確定する(first match wins)。** 後続の規則が先行の規則を
上書きすることはない。ある規則が該当した時点で、それより下の規則は一切評価しない。

## IC-C1 — reopen(最優先)

候補のうち、**根本原因または観測症状が実質同じ**ものが 1 件でもあれば `reopen` で確定する。
表面の切り口・語彙・スコープ記述の違いを非該当の理由にしてはならない。
`target` = 該当候補の番号。`children` / `related` は空。

## IC-C2 — sub-of(既存 meta 親への従属)

IC-C1 が非該当のとき**のみ**評価する。`relation_status` が `resolved` の候補のうち、
`parent_is_meta: true` の親を持つものがあれば、その**親番号**への `sub-of` で確定する。
複数該当するときは主題が最も近い親を 1 つ選ぶ。候補自身が meta 親である場合は
その候補番号を `target` にしてよい。`children` / `related` は空。

## IC-C3 — make-parent(孤立候補の集約)

IC-C1 と IC-C2 がともに非該当のとき**のみ**評価する。`relation_status` が `resolved` で
`parent_number` が全て `null` の、同一クラスとみなせる候補が 2 件以上あるとき `make-parent`。
`children` にその孤立候補群を列挙し、`target` は `null`。

## IC-C4 — sibling / none

IC-C1 / IC-C2 / IC-C3 のいずれにも該当しない場合のみ。関連する候補があれば `sibling`
(`related` に列挙、`target` は `null`)、まったく関連がなければ `none`
(`target` は `null`、`children` / `related` は空)。

## 補助規則

- 候補の年齢は **tie-break にのみ**使う。順序は closed > open、新しい(newer) > 古い、
  番号が小さい(smaller) > 大きい。
- 数値のしきい値は設けない。判断は内容の同一性についての説明可能な根拠で行う。
- `relation_status` が `resolved` でない候補については IC-C2 / IC-C3 の条件を評価しない
  (「不明」を「親なし」と誤読しないため)。全候補が未解決なら IC-C1 → IC-C4 のみで判定する。
- `reason` は 1 文。どの規則で確定したかがわかる書き方にする。
