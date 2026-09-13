#!/usr/bin/env node
// review-orchestrator.js の fail_fast 判定（detectR1Failure / detectR2Failure）は AI を
// 使わない決定論的な判定だが、review-orchestrator.js 自体は Workflow tool のサンドボックス内
// でしか実行できず（fs 等の Node.js API が使えない）、ロジックを別モジュールへ切り出して
// require することもできない。そのためソースの該当ブロックをマーカーコメント間で抜き出し、
// 素の Node.js から評価して検証する（scoring.test.js と同じ方式）。
//
// AI を一切呼ばないため実行コストはゼロ（トークン消費なし）。CI で毎回実行できる。

const fs = require('fs')
const path = require('path')

const sourcePath = path.join(__dirname, '..', 'workflows', 'review-orchestrator.js')
const source = fs.readFileSync(sourcePath, 'utf8')

const startMarker = '// ==FAILFAST_UNIT_START=='
const endMarker = '// ==FAILFAST_UNIT_END=='
const startIdx = source.indexOf(startMarker)
const endIdx = source.indexOf(endMarker)
if (startIdx === -1 || endIdx === -1) {
  throw new Error(`review-orchestrator.js からマーカーが見つからない: ${startMarker} / ${endMarker}`)
}
const unitBody = source.slice(source.indexOf('\n', startIdx) + 1, endIdx)

const { detectR1Failure, detectR2Failure, containsSafetyBlockString } = new Function(
  `${unitBody}\nreturn { detectR1Failure, detectR2Failure, containsSafetyBlockString }`,
)()

let passed = 0
let failed = 0

function assertEqual(actual, expected, label) {
  if (actual === expected) {
    passed++
    return
  }
  failed++
  console.error(`❌ ${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`)
}

function r1Entry(raw) {
  return { id: 'X-bug_logic', engine: 'claude', raw }
}

// IAM 権限の指摘は「〜を許可してください」で結ぶのが自然な言い回しで、これが安全確認の
// 定型文と衝突してレビュー全体が retryable: false で止まった。この2件がその再発防止。
const iamFindingJson = JSON.stringify({
  findings: [{
    file: 'infra/lib/batch-stack.ts',
    line: 42,
    category: 'security',
    severity: 'MUST',
    confidence: 85,
    description: 'EventBridge に渡すロールの PassRole 条件が絞られていない',
    evidence: 'EventBridge に渡すロールについて iam:PassedToService = events.amazonaws.com を許可してください。',
  }],
})

{
  const r = detectR1Failure(r1Entry(iamFindingJson))
  assertEqual(r, null, 'IAM 指摘（許可してください）を含む正常な findings JSON は成功扱い')
}

{
  const bare = 'EventBridge に渡すロールについて iam:PassedToService = events.amazonaws.com を許可してください。'
  assertEqual(containsSafetyBlockString(bare), null, '裸の「〜を許可してください」は安全確認ブロックとみなさない')
}

{
  // 判定順の入れ替えそのものを固定する。禁止語は本文に混ざり得るので、有効な JSON を
  // 返せている限り落としてはいけない。
  const raw = `${iamFindingJson}\nThe log shows the review completed.`
  assertEqual(detectR1Failure(r1Entry(raw)), null, '有効な findings JSON を返せていれば禁止語が混ざっても成功扱い')
}

{
  const r = detectR1Failure(r1Entry('Bash の実行を許可してください。承認が得られるまで進められません。'))
  assertEqual(r && r.reason, 'safety block', 'エージェント自身の行動許可を求める文言は安全確認ブロック')
  assertEqual(r && r.retryable, false, '安全確認ブロックはリトライ対象外')
}

{
  const r = detectR1Failure(r1Entry('権限が拒否されました。'))
  assertEqual(r && r.reason, 'safety block', '「権限が拒否されました」は安全確認ブロック')
}

{
  const r = detectR1Failure(r1Entry('The log shows the process is still running.'))
  assertEqual(r && r.reason, 'forbidden string', 'JSON を返せていない paraphrase は禁止語混入')
  assertEqual(r && r.retryable, true, '禁止語混入はリトライ対象')
}

{
  const r = detectR1Failure(r1Entry('レビューできませんでした。'))
  assertEqual(r && r.reason, 'json parse failed', 'JSON でも禁止語でもない本文は JSON parse 失敗')
}

{
  const r = detectR1Failure(r1Entry(JSON.stringify({ result: 'ok' })))
  assertEqual(r && r.reason, 'findings missing', 'findings 配列が無い JSON は形状不一致')
}

{
  const r = detectR1Failure(null)
  assertEqual(r && r.reason, 'null result', 'entry が null なら null result')
}

{
  const raw = JSON.stringify({ validations: [{ original_index: 0, verdict: 'valid' }], new_findings: [] })
  assertEqual(detectR2Failure({ id: 'V-claude', raw }), null, 'validations を持つ JSON は成功扱い')
}

{
  const raw = JSON.stringify({ validations: [], new_findings: [{ category: 'convention', confidence: 70 }] })
  assertEqual(detectR2Failure({ id: 'V-claude', raw }), null, 'new_findings だけでも成功扱い')
}

{
  const r = detectR2Failure({ id: 'V-claude', raw: JSON.stringify({ result: 'ok' }) })
  assertEqual(r && r.reason, 'validations missing', 'validations も new_findings も無い JSON は形状不一致')
}

console.log(`---\n検査: ${passed + failed} 件 / 成功: ${passed} 件 / 失敗: ${failed} 件`)
process.exit(failed > 0 ? 1 : 0)
