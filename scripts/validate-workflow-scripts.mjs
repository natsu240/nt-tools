// plugins/*/workflows/*.js が Workflow tool に渡して実際にパースできるかを検査する。
//
// Workflow tool は台本を「export を外した async 関数の本体」として扱うため、
// 同じ形に整えて V8 にコンパイルさせるだけで、実行せずにパースエラーを検出できる。
//
// `node --check` では代用できない。export を含むファイルでは catch / finally の無い try を
// 構文エラーとして報告しないため、テンプレートリテラルの閉じ忘れで try が壊れていても通る
// （実測: `export const meta = {}` + `try {}` だけのファイルが exit 0 になる）。
// 実際に review-orchestrator.js が Workflow tool から
// "Missing catch or finally clause" で起動できない状態を、node --check は5バージョン連続で
// 見逃していた。

import { readdirSync, readFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'

const PLUGINS_DIR = 'plugins'
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

/** 各プラグインの workflows ディレクトリ配下にある台本を列挙する */
function collectWorkflowScripts() {
  const scripts = []
  for (const plugin of readdirSync(PLUGINS_DIR)) {
    const workflowsDir = join(PLUGINS_DIR, plugin, 'workflows')
    if (!existsSync(workflowsDir)) {
      continue
    }
    for (const file of readdirSync(workflowsDir)) {
      if (file.endsWith('.js') || file.endsWith('.mjs')) {
        scripts.push(join(workflowsDir, file))
      }
    }
  }
  return scripts.sort()
}

/**
 * 台本を Workflow tool と同じ「async 関数の本体」の形に整える。
 *
 * 行頭の `export` だけを落とす。関数本体に export 宣言は書けないため、
 * 外さないとコンパイル自体が通らず、本来検出したい構文エラーが隠れる。
 */
function toFunctionBody(source) {
  return source.replace(/^export\s+/gm, '')
}

/** パースできれば null、できなければエラーメッセージを返す */
function findParseError(path) {
  const source = readFileSync(path, 'utf8')
  try {
    new AsyncFunction(toFunctionBody(source))
    return null
  } catch (e) {
    return e.message
  }
}

// 引数でパスを渡した場合はそれだけを検査する（このスクリプト自体の動作確認用）
const scripts = process.argv.length > 2 ? process.argv.slice(2) : collectWorkflowScripts()
if (scripts.length === 0) {
  console.error('workflow 台本が1本も見つからない。検査対象の探索条件を確認しろ。')
  process.exit(1)
}

let failed = 0
for (const path of scripts) {
  const error = findParseError(path)
  if (error === null) {
    console.log(`OK   ${path}`)
    continue
  }
  failed++
  console.error(`NG   ${path}`)
  console.error(`     ${error}`)
}

if (failed > 0) {
  console.error('')
  console.error(`${failed} 本の workflow 台本が Workflow tool でパースできない。`)
  console.error('テンプレートリテラルの閉じ忘れ・余分なバッククォートを疑え。')
  process.exit(1)
}

console.log('')
console.log(`workflow 台本 ${scripts.length} 本すべてパース可能。`)
