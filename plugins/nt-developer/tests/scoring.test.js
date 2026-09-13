#!/usr/bin/env node
// review-orchestrator.js のスコアリング/severity_label 判定は AI を使わない決定論的な
// 計算だが、review-orchestrator.js 自体は Workflow tool のサンドボックス内でしか実行
// できず（fs 等の Node.js API が使えない）、ロジックを別モジュールへ切り出して require
// することもできない。そのためソースの該当ブロックをマーカーコメント間で抜き出し、
// 素の Node.js から評価して検証する。
//
// AI を一切呼ばないため実行コストはゼロ（トークン消費なし）。CI で毎回実行できる。

const fs = require('fs')
const path = require('path')

const sourcePath = path.join(__dirname, '..', 'workflows', 'review-orchestrator.js')
const source = fs.readFileSync(sourcePath, 'utf8')

function extractUnit(startMarker, endMarker) {
  const startIdx = source.indexOf(startMarker)
  const endIdx = source.indexOf(endMarker)
  if (startIdx === -1 || endIdx === -1) {
    throw new Error(`review-orchestrator.js からマーカーが見つからない: ${startMarker} / ${endMarker}`)
  }
  const bodyStart = source.indexOf('\n', startIdx) + 1
  return source.slice(bodyStart, endIdx)
}

const scoringBody = extractUnit('// ==SCORING_UNIT_START==', '// ==SCORING_UNIT_END==')
const newFindingBody = extractUnit('// ==NEWFINDING_UNIT_START==', '// ==NEWFINDING_UNIT_END==')

const computeScored = new Function('f', 'i', 'verdictByIndex', scoringBody)
const computeNewFinding = new Function('nf', `${newFindingBody}\nreturn { score, severityLabel }`)

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

function baseFinding(overrides) {
  return {
    file: 'a.php',
    line: 1,
    category: 'bug',
    severity: 'MUST',
    confidence: 0,
    description: '',
    evidence: '',
    _source_agents: [],
    _engines: [],
    _dimension: 'bug',
    ...overrides,
  }
}

const noVotes = new Map()

{
  const r = computeScored(baseFinding({ confidence: 90 }), 0, noVotes)
  assertEqual(r.severity_label, '必須対応', 'confidence=90 の bug は無投票でも必須対応')
}

{
  const r = computeScored(baseFinding({ confidence: 80 }), 0, noVotes)
  assertEqual(r.severity_label, '必須対応', 'confidence=80 の bug は必須対応')
}

{
  const r = computeScored(baseFinding({ confidence: 79 }), 0, noVotes)
  assertEqual(r.severity_label, '任意対応', 'confidence=79 の bug は任意対応')
}

{
  const r = computeScored(baseFinding({ category: 'convention', severity: 'MUST', confidence: 90 }), 0, noVotes)
  assertEqual(r.severity_label, '必須対応', 'convention+MUST は confidence=90 で必須対応')
}

{
  const r = computeScored(baseFinding({ category: 'convention', severity: 'MUST', confidence: 89 }), 0, noVotes)
  assertEqual(r.severity_label, '任意対応', 'convention+MUST は confidence=89 だと任意対応（bug 系より閾値が厳しい）')
}

{
  const r = computeScored(baseFinding({ category: 'convention', severity: 'SHOULD', confidence: 90 }), 0, noVotes)
  assertEqual(r.severity_label, '任意対応', 'convention+SHOULD は confidence=90 でも任意対応')
}

{
  // ここが本題: 正誤検証がバグを誤って false_positive 2件と判定すると
  // confidence 90 -> 40 に落ち、必須対応から任意対応へ転落する（一覧にも出ない）。
  // この転落条件そのものを固定するテスト。
  const votes = new Map([[0, [{ verdict: 'false_positive' }, { verdict: 'false_positive' }]]])
  const r = computeScored(baseFinding({ confidence: 90 }), 0, votes)
  assertEqual(r.confidence, 40, 'false_positive 2件で confidence が 90->40 に減点される')
  assertEqual(r.severity_label, '任意対応', 'false_positive 2件で必須対応から任意対応に転落する')
}

{
  const votes = new Map([[0, [{ verdict: 'valid' }, { verdict: 'valid' }]]])
  const r = computeScored(baseFinding({ confidence: 75 }), 0, votes)
  assertEqual(r.confidence, 95, 'valid 2件で confidence が 75->95 に加点される')
  assertEqual(r.severity_label, '必須対応', 'valid 2件で必須対応まで上がる')
}


{
  const votes = new Map([[0, [{ verdict: 'false_positive' }, { verdict: 'false_positive' }]]])
  const r = computeScored(baseFinding({ confidence: 10 }), 0, votes)
  assertEqual(r.confidence, 0, '減点後の負のスコアは0にクランプされる')
}


{
  const votes = new Map([[0, [{ verdict: 'false_positive' }, { verdict: 'valid', spec_check: 'x'.repeat(10) }]]])
  const r = computeScored(baseFinding({ confidence: 100 }), 0, votes)
  assertEqual(r.confidence, 80, 'エンジン一致が無いとき fp1票+valid1票で confidence は 80 になる')
  assertEqual(r.severity_label, '任意対応', 'confidence が閾値ちょうどでも fp 1票なら必須対応にしない')
}

{
  // spec_check が薄い valid 票は「確認した体で照合していない」可能性があるため加点に使わない。
  const votes = new Map([[0, [{ verdict: 'valid', weak_spec_check: true }]]])
  const r = computeScored(baseFinding({ confidence: 75 }), 0, votes)
  assertEqual(r.confidence, 75, 'weak_spec_check な valid 票は加点に使われない')
}

{
  const votes = new Map([[0, [{ verdict: 'valid', weak_spec_check: false }]]])
  const r = computeScored(baseFinding({ confidence: 75 }), 0, votes)
  assertEqual(r.confidence, 85, 'weak_spec_check ではない valid 票は通常どおり加点される')
}

{
  const r = computeNewFinding({ category: 'security', confidence: 90 })
  assertEqual(r.severityLabel, '必須対応', 'new_finding: confidence=90 の security は必須対応')
}

{
  const r = computeNewFinding({ category: 'convention', confidence: 95 })
  assertEqual(r.severityLabel, '任意対応', 'new_finding: convention は confidence が高くても bug 相当ではないため任意対応')
}

console.log(`---\n検査: ${passed + failed} 件 / 成功: ${passed} 件 / 失敗: ${failed} 件`)
process.exit(failed > 0 ? 1 : 0)
