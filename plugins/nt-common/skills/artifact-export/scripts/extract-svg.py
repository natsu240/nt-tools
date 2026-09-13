#!/usr/bin/env python3
# Artifact の HTML には claude.ai 側のプレビュー枠のコードが混ざっており、DOM パーサーに通すとその枠まで構造として解釈するため、文字列走査で対象の <svg> だけを切り出す。
# HTML の名前付き実体参照（&nbsp; 等）は XML では未定義なので、書き出し前に数値文字参照へ置き換える。

import argparse
import html.entities
import json
import re
import sys
import xml.etree.ElementTree as ElementTree

# Artifact の実装（クラス名の付け方・アイコン ID の命名・スプライトの置き方）が変わったときに見る場所はここだけだ。
# 個別の命名規則には依存させず、タグ・属性という HTML/SVG の仕様側の形だけを見ている。
RE_STYLE = re.compile(r'<style\b[^>]*>(.*?)</style>', re.S | re.I)
RE_SCRIPT = re.compile(r'<script\b[^>]*>.*?</script>', re.S | re.I)
RE_STYLESHEET_LINK = re.compile(r'<link\b[^>]*\brel\s*=\s*["\']stylesheet["\'][^>]*>', re.I)
RE_HREF_ATTR = re.compile(r'\bhref\s*=\s*["\']([^"\']+)["\']', re.I)
RE_VIEWBOX_ATTR = re.compile(r'\bviewBox\s*=\s*["\']([^"\']+)["\']', re.I)
RE_ID_ATTR = re.compile(r'(?<![\w-])id\s*=\s*["\']([^"\']+)["\']')
RE_CLASS_ATTR = re.compile(r'\bclass\s*=\s*["\']([^"\']*)["\']')
RE_TAG_NAME = re.compile(r'<([A-Za-z][\w:-]*)')
RE_ID_REFERENCE = re.compile(r'(?:xlink:)?href\s*=\s*["\']#([^"\']+)["\']|url\(\s*["\']?#([^)"\']+)["\']?\s*\)')
RE_HEADING = re.compile(r'<h[1-6]\b[^>]*>(.*?)</h[1-6]>', re.S | re.I)
RE_FIGCAPTION = re.compile(r'<figcaption\b[^>]*>(.*?)</figcaption>', re.S | re.I)
RE_NAMED_ENTITY = re.compile(r'&([A-Za-z][A-Za-z0-9]*);')
RE_BARE_AMPERSAND = re.compile(r'&(?!#\d+;|#x[0-9A-Fa-f]+;|[A-Za-z][A-Za-z0-9]*;)')

XML_BUILTIN_ENTITIES = {'amp', 'lt', 'gt', 'quot', 'apos'}
DRAWABLE_TAGS = ('use', 'path', 'rect', 'circle', 'ellipse', 'line', 'polyline', 'polygon', 'text', 'image', 'foreignObject')
# 中に規則を抱える at-rule。中身を再帰的に絞り、1件も残らなければ丸ごと落とす。
# ここに無い at-rule（@font-face / @keyframes 等）は、絞り込む対象のセレクタを持たないのでそのまま残す。
AT_RULES_RECURSE = {'media', 'supports', 'layer', 'container', 'scope'}
# 単独 SVG では root 要素そのものが該当するため、常に「存在する」として扱うセレクタ
ALWAYS_PRESENT_SELECTORS = {'*', ':root', 'svg'}

FIGCAPTION_SEARCH_WINDOW = 3000


def find_elements(markup, tag):
    """入れ子を数えながら tag の開始・終了位置を対で返す。入れ子の内側は結果に含めない。"""
    open_pattern = re.compile(r'<' + tag + r'\b', re.I)
    close_token = ('</' + tag).lower()
    lowered = markup.lower()
    spans = []
    position = 0
    while True:
        opening = open_pattern.search(markup, position)
        if opening is None:
            return spans
        cursor = opening.start()
        depth = 0
        while cursor < len(markup):
            next_open = open_pattern.search(markup, cursor)
            next_close = lowered.find(close_token, cursor)
            if next_open is not None and (next_close == -1 or next_open.start() < next_close):
                depth += 1
                cursor = next_open.end()
                continue
            if next_close == -1:
                return spans
            depth -= 1
            cursor = markup.find('>', next_close)
            if cursor == -1:
                return spans
            cursor += 1
            if depth == 0:
                spans.append((opening.start(), cursor))
                break
        position = cursor


def find_element_by_id(markup, element_id):
    """id を持つ要素を、タグ名を問わず1件切り出す。<symbol> 以外の <marker> や <clipPath> も同じ経路で拾える。"""
    for match in RE_ID_ATTR.finditer(markup):
        if match.group(1) != element_id:
            continue
        tag_start = markup.rfind('<', 0, match.start())
        if tag_start == -1:
            continue
        tag_match = RE_TAG_NAME.match(markup, tag_start)
        if tag_match is None:
            continue
        tag_end = markup.find('>', match.end())
        if tag_end == -1:
            continue
        if markup[tag_end - 1] == '/':
            return markup[tag_start:tag_end + 1]
        for start, end in find_elements(markup[tag_start:], tag_match.group(1)):
            if start == 0:
                return markup[tag_start:tag_start + end]
    return None


def strip_tags(markup):
    text = re.sub(r'\s+', ' ', re.sub(r'<[^>]*>', '', markup)).strip()
    return html.unescape(text)


def opening_tag_of(markup):
    return markup[:markup.find('>') + 1]


def body_of(markup):
    return markup[markup.find('>') + 1:markup.rfind('<')]


def parse_viewbox(markup):
    match = RE_VIEWBOX_ATTR.search(opening_tag_of(markup))
    if match is None:
        return None
    numbers = re.split(r'[\s,]+', match.group(1).strip())
    if len(numbers) != 4:
        return None
    try:
        return [float(value) for value in numbers]
    except ValueError:
        return None


def definitions_only(markup):
    """描画要素が <symbol> / <defs> の外に無い <svg>。アイコンのスプライト置き場がこれに当たる。"""
    if '<symbol' not in markup.lower():
        return False
    stripped = markup
    for tag in ('symbol', 'defs'):
        for start, end in reversed(find_elements(stripped, tag)):
            stripped = stripped[:start] + stripped[end:]
    return not any(re.search(r'<' + tag + r'\b', stripped, re.I) for tag in DRAWABLE_TAGS)


def nearest_heading(html_source, position):
    headings = list(RE_HEADING.finditer(html_source, 0, position))
    if not headings:
        return None
    return strip_tags(headings[-1].group(1))


def nearest_caption(html_source, position):
    match = RE_FIGCAPTION.search(html_source, position, position + FIGCAPTION_SEARCH_WINDOW)
    if match is None:
        return None
    return strip_tags(match.group(1))


def referenced_ids(markup):
    found = set()
    for match in RE_ID_REFERENCE.finditer(markup):
        found.add(match.group(1) or match.group(2))
    return found


def defined_ids(markup):
    return {match.group(1) for match in RE_ID_ATTR.finditer(markup)}


def collect_svg_candidates(html_source):
    figures = []
    skipped = []
    for html_index, (start, end) in enumerate(find_elements(html_source, 'svg')):
        markup = html_source[start:end]
        entry = {
            'html_index': html_index,
            'heading': nearest_heading(html_source, start),
            'caption': nearest_caption(html_source, end),
        }
        viewbox = parse_viewbox(markup)
        if viewbox is None:
            skipped.append({**entry, 'reason': 'viewBox が無い'})
            continue
        if definitions_only(markup):
            skipped.append({**entry, 'reason': '定義置き場（描画要素が <symbol> の外に無い）'})
            continue
        entry['index'] = len(figures)
        entry['viewBox'] = ' '.join(f'{value:g}' for value in viewbox)
        entry['width'] = viewbox[2]
        entry['height'] = viewbox[3]
        entry['referenced_ids'] = sorted(referenced_ids(markup))
        figures.append(entry)
    return figures, skipped


def skip_css_string(css, cursor):
    quote = css[cursor]
    cursor += 1
    while cursor < len(css):
        if css[cursor] == '\\':
            cursor += 2
            continue
        if css[cursor] == quote:
            return cursor + 1
        cursor += 1
    return cursor


def split_css_blocks(css):
    """トップレベルの規則を (prelude, body) に切る。body が None なら本文の無い宣言（@import 等）。"""
    blocks = []
    prelude_start = 0
    prelude_fragments = []
    depth = 0
    body_start = None
    cursor = 0
    while cursor < len(css):
        if css.startswith('/*', cursor):
            comment_end = css.find('*/', cursor + 2)
            comment_end = len(css) if comment_end == -1 else comment_end + 2
            if depth == 0:
                prelude_fragments.append(css[prelude_start:cursor])
                prelude_start = comment_end
            cursor = comment_end
            continue
        character = css[cursor]
        if character in '"\'':
            cursor = skip_css_string(css, cursor)
            continue
        if character == '{':
            depth += 1
            if depth == 1:
                body_start = cursor + 1
        elif character == '}':
            depth -= 1
            if depth == 0:
                prelude_fragments.append(css[prelude_start:body_start - 1])
                blocks.append((''.join(prelude_fragments), css[body_start:cursor]))
                prelude_fragments = []
                prelude_start = cursor + 1
        elif character == ';' and depth == 0:
            prelude_fragments.append(css[prelude_start:cursor])
            statement = ''.join(prelude_fragments).strip()
            if statement:
                blocks.append((statement, None))
            prelude_fragments = []
            prelude_start = cursor + 1
        cursor += 1
    return blocks


def selector_tokens(selector):
    cleaned = re.sub(r'\[[^\]]*\]', '', selector)
    cleaned = re.sub(r':(?!root\b):?[A-Za-z-]+(?:\([^)]*\))?', '', cleaned)
    tokens = set()
    for part in re.split(r'[\s>+~]+', cleaned):
        part = part.strip()
        if not part:
            continue
        if part.startswith(':root'):
            tokens.add(':root')
            continue
        element = re.match(r'[A-Za-z*][\w-]*', part)
        if element is not None:
            tokens.add(element.group(0).lower())
        tokens.update(re.findall(r'[.#][\w-]+', part))
    return tokens


def token_present(token, usage):
    if token in ALWAYS_PRESENT_SELECTORS:
        return True
    if token.startswith('.'):
        return token[1:] in usage['classes']
    if token.startswith('#'):
        return token[1:] in usage['ids']
    return token in usage['elements']


def selector_applies(selector, usage):
    """セレクタに出てくる要素名・クラス・id が、取り出した SVG の中で実際に使われているかで判定する。"""
    for alternative in selector.split(','):
        tokens = selector_tokens(alternative)
        if not tokens:
            continue
        if all(token_present(token, usage) for token in tokens):
            return True
    return False


def collect_usage(markup):
    classes = set()
    for match in RE_CLASS_ATTR.finditer(markup):
        classes.update(match.group(1).split())
    return {
        'classes': classes,
        'ids': defined_ids(markup),
        'elements': {name.lower() for name in RE_TAG_NAME.findall(markup)},
    }


def filter_css(css, usage):
    kept = []
    for prelude, body in split_css_blocks(css):
        selector = prelude.strip()
        if not selector:
            continue
        if selector.startswith('@'):
            kept.extend(filter_at_rule(selector, body, usage))
            continue
        if body is not None and selector_applies(selector, usage):
            kept.append(f'{selector} {{{body}}}')
    return '\n'.join(kept)


def filter_at_rule(selector, body, usage):
    if body is None:
        return [selector + ';']
    at_rule = re.match(r'@([\w-]+)', selector).group(1).lower()
    if at_rule in AT_RULES_RECURSE:
        inner = filter_css(body, usage)
        if not inner:
            return []
        return [f'{selector} {{\n{inner}\n}}']
    return [f'{selector} {{{body}}}']


def collect_css(html_source, usage):
    """外部スタイルシートの <link> は @import に変えて持ち込む。単独 SVG には <link> が付いてこないため。"""
    imports = []
    for link in RE_STYLESHEET_LINK.finditer(html_source):
        href = RE_HREF_ATTR.search(link.group(0))
        if href is not None:
            imports.append(f'@import url("{href.group(1)}");')
    without_scripts = RE_SCRIPT.sub('', html_source)
    rules = [filter_css(match.group(1), usage) for match in RE_STYLE.finditer(without_scripts)]
    return '\n'.join(imports + [rule for rule in rules if rule])


def split_svg_defs(svg_markup):
    """svg 要素から defs をすべて取り除いた描画本体と、defs の中身を返す。"""
    drawing = svg_markup
    pools = []
    for start, end in reversed(find_elements(svg_markup, 'defs')):
        pools.append(svg_markup[start:end])
        drawing = drawing[:start] + drawing[end:]
    return body_of(drawing), '\n'.join(reversed(pools))


def collect_definitions(html_source, svg_markup):
    """描画本体から参照の連鎖を辿り、実際に使われている id の定義だけを集める。svg 自身の defs も絞り込みの対象にする。"""
    drawing_body, local_defs = split_svg_defs(svg_markup)
    search_pool = local_defs + html_source.replace(svg_markup, '')
    available = set()
    pending = referenced_ids(drawing_body)
    collected = []
    missing = []
    while pending:
        element_id = pending.pop()
        if element_id in available:
            continue
        available.add(element_id)
        definition = find_element_by_id(search_pool, element_id)
        if definition is None:
            missing.append(element_id)
            continue
        collected.append(definition)
        pending |= referenced_ids(definition) - available
    return drawing_body, collected, sorted(missing)


def to_xml_entities(markup):
    def replace(match):
        name = match.group(1)
        if name in XML_BUILTIN_ENTITIES:
            return match.group(0)
        character = html.entities.html5.get(name + ';')
        if character is None:
            return match.group(0)
        return ''.join(f'&#{ord(letter)};' for letter in character)

    return RE_NAMED_ENTITY.sub(replace, RE_BARE_AMPERSAND.sub('&amp;', markup))


def build_opening_tag(svg_markup, viewbox):
    opening = opening_tag_of(svg_markup)
    if 'xmlns=' not in opening:
        opening = opening[:-1] + ' xmlns="http://www.w3.org/2000/svg">'
    if 'xlink:' in svg_markup and 'xmlns:xlink=' not in opening:
        opening = opening[:-1] + ' xmlns:xlink="http://www.w3.org/1999/xlink">'
    opening = re.sub(r'\s+(width|height)\s*=\s*["\'][^"\']*["\']', '', opening)
    return opening[:-1] + f' width="{viewbox[2]:g}" height="{viewbox[3]:g}">'


def build_standalone_svg(html_source, svg_markup, background):
    viewbox = parse_viewbox(svg_markup)
    drawing_body, definitions, missing = collect_definitions(html_source, svg_markup)
    usage = collect_usage(drawing_body + ''.join(definitions))
    css = collect_css(html_source, usage)

    injected = []
    if css or definitions:
        injected.append('<defs>')
        if css:
            injected.append(f'<style type="text/css"><![CDATA[\n{css}\n]]></style>')
        injected.extend(definitions)
        injected.append('</defs>')
    if background:
        injected.append(f'<rect x="{viewbox[0]:g}" y="{viewbox[1]:g}" width="{viewbox[2]:g}" height="{viewbox[3]:g}" fill="{background}"/>')

    svg = build_opening_tag(svg_markup, viewbox) + '\n' + '\n'.join(injected) + drawing_body + '</svg>'
    return to_xml_entities(svg), {
        'width': viewbox[2],
        'height': viewbox[3],
        'embedded_definitions': len(definitions),
        'unresolved_ids': missing,
    }


def read_html(path):
    with open(path, encoding='utf-8', errors='replace') as source:
        return source.read()


def command_list(arguments):
    figures, skipped = collect_svg_candidates(read_html(arguments.html))
    print(json.dumps({'figures': figures, 'skipped': skipped}, ensure_ascii=False, indent=2))
    return 0


def command_extract(arguments):
    html_source = read_html(arguments.html)
    figures, _ = collect_svg_candidates(html_source)
    if arguments.index >= len(figures):
        print(f'図が {len(figures)} 枚しか無いので index={arguments.index} は指定できない', file=sys.stderr)
        return 1

    start, end = find_elements(html_source, 'svg')[figures[arguments.index]['html_index']]
    svg, report = build_standalone_svg(html_source, html_source[start:end], arguments.background)

    try:
        ElementTree.fromstring(svg)
    except ElementTree.ParseError as error:
        print(f'組み立てた SVG が XML としてパースできない: {error}', file=sys.stderr)
        return 1

    with open(arguments.out, 'w', encoding='utf-8') as destination:
        destination.write('<?xml version="1.0" encoding="UTF-8"?>\n' + svg + '\n')

    print(json.dumps({'path': arguments.out, 'xml_valid': True, **report}, ensure_ascii=False, indent=2))
    return 0


def main():
    parser = argparse.ArgumentParser(description='Artifact の HTML からインライン SVG の図を単独ファイルとして取り出す')
    subcommands = parser.add_subparsers(dest='command', required=True)

    list_parser = subcommands.add_parser('list', help='書き出せる図を一覧する')
    list_parser.add_argument('html')

    extract_parser = subcommands.add_parser('extract', help='図を1枚、自己完結 SVG として書き出す')
    extract_parser.add_argument('html')
    extract_parser.add_argument('--index', type=int, required=True, help='list の figures[].index')
    extract_parser.add_argument('--out', required=True)
    extract_parser.add_argument('--background', default='', help='背景を塗る CSS 色。既定は透明')

    arguments = parser.parse_args()
    if arguments.command == 'list':
        return command_list(arguments)
    return command_extract(arguments)


if __name__ == '__main__':
    sys.exit(main())
