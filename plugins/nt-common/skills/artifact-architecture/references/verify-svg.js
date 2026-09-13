// ブラウザ上でそのまま評価させる検証関数。
// Artifact のプレビュー用に保存した一時HTMLファイルを file:// で開いた状態で実行し、戻り値のうち severity: "error" が0件になるまで publish 前に直せ。
() => {
  const issues = [];
  const SAMPLE_COUNT = 24;
  const CENTER_TOLERANCE = 2;
  const PATH_END_MARGIN = 6;
  // これを超える面積のノードは器（グループ枠・背景）として扱い、矢印の着地先の候補から外す。
  const CONTAINER_AREA_RATIO = 0.25;
  const MIN_SPILL_RATIO = 0.4;

  const samplePoints = (el) => {
    const tag = el.tagName.toLowerCase();
    if (tag === 'line') {
      const x1 = parseFloat(el.getAttribute('x1'));
      const y1 = parseFloat(el.getAttribute('y1'));
      const x2 = parseFloat(el.getAttribute('x2'));
      const y2 = parseFloat(el.getAttribute('y2'));
      return Array.from({ length: SAMPLE_COUNT + 1 }, (_, i) => {
        const t = i / SAMPLE_COUNT;
        return { x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t };
      });
    }
    if (typeof el.getTotalLength !== 'function') {
      return [];
    }
    const length = el.getTotalLength();
    if (!length) {
      return [];
    }
    return Array.from({ length: SAMPLE_COUNT + 1 }, (_, i) => el.getPointAtLength((length * i) / SAMPLE_COUNT));
  };

  const endPoint = (el) => {
    const tag = el.tagName.toLowerCase();
    if (tag === 'line') {
      return { x: parseFloat(el.getAttribute('x2')), y: parseFloat(el.getAttribute('y2')) };
    }
    if (typeof el.getTotalLength !== 'function') {
      return null;
    }
    return el.getPointAtLength(el.getTotalLength());
  };

  const pointInBox = (point, box, margin = 0) =>
    point.x >= box.x - margin &&
    point.x <= box.x + box.width + margin &&
    point.y >= box.y - margin &&
    point.y <= box.y + box.height + margin;

  const boxOf = (el) => {
    try {
      return el.getBBox();
    } catch {
      return null;
    }
  };

  const areaOf = (box) => box.width * box.height;

  const boxesIntersect = (a, b) =>
    a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;

  const boxDistance = (a, b) => {
    const dx = Math.max(a.x - (b.x + b.width), b.x - (a.x + a.width), 0);
    const dy = Math.max(a.y - (b.y + b.height), b.y - (a.y + a.height), 0);
    return Math.hypot(dx, dy);
  };

  const innerPadding = (inner, outer) =>
    Math.min(
      inner.x - outer.x,
      outer.x + outer.width - (inner.x + inner.width),
      inner.y - outer.y,
      outer.y + outer.height - (inner.y + inner.height)
    );

  // data-role の付け忘れで検査が空振りしないよう、塗りが無く線だけの矩形を計算後のスタイルからグループ枠と判定する。
  const isGroupBorder = (el) => {
    if (el.matches('[data-role="group-border"]')) {
      return true;
    }
    if (el.tagName.toLowerCase() !== 'rect') {
      return false;
    }
    const style = getComputedStyle(el);
    const unfilled = style.fill === 'none' || style.fill === 'rgba(0, 0, 0, 0)' || style.fillOpacity === '0';
    const stroked = style.stroke !== 'none' && style.strokeOpacity !== '0';
    return unfilled && stroked;
  };

  const findDefinedClasses = () => {
    const definedClasses = new Set();
    [...document.styleSheets].forEach((sheet) => {
      let rules;
      try {
        rules = [...sheet.cssRules];
      } catch {
        return;
      }
      rules.forEach((rule) => {
        rule.selectorText?.match(/\.[\w-]+/g)?.forEach((m) => definedClasses.add(m.slice(1)));
      });
    });
    return definedClasses;
  };

  const horizontalGaps = (svg) => {
    const wrapper = svg.parentElement;
    if (!wrapper) {
      return null;
    }
    const svgRect = svg.getBoundingClientRect();
    if (!svgRect.width || !svgRect.height) {
      return null;
    }
    const wrapperRect = wrapper.getBoundingClientRect();
    const wrapperStyle = getComputedStyle(wrapper);
    return {
      left: svgRect.left - (wrapperRect.left + parseFloat(wrapperStyle.paddingLeft)),
      right: wrapperRect.right - parseFloat(wrapperStyle.paddingRight) - svgRect.right,
    };
  };

  document.querySelectorAll('svg').forEach((svg, svgIndex) => {
    const texts = [...svg.querySelectorAll('text')];
    const paths = [...svg.querySelectorAll('path, line')];
    const icons = [...svg.querySelectorAll('use')]
      .map((el) => ({ el, box: boxOf(el) }))
      .filter((n) => n.box);
    const shapes = [...svg.querySelectorAll('rect, circle, ellipse')]
      .map((el) => ({ el, box: boxOf(el), border: isGroupBorder(el) }))
      .filter((n) => n.box);
    const borders = shapes.filter((n) => n.border);
    const contentNodes = shapes.filter((n) => !n.border);
    const svgBox = boxOf(svg);
    const svgArea = svgBox ? areaOf(svgBox) : 0;

    const fontSizes = texts
      .map((t) => parseFloat(getComputedStyle(t).fontSize))
      .filter((v) => v > 0)
      .sort((a, b) => a - b);
    const baseFont = fontSizes.length ? fontSizes[Math.floor(fontSizes.length / 2)] : 12;
    const MIN_NODE_GAP = baseFont * 1.2;
    const MIN_TEXT_PAD = baseFont * 0.4;
    const MIN_ICON_GAP = baseFont * 0.5;

    texts.forEach((textEl) => {
      const textBox = boxOf(textEl);
      if (!textBox) {
        return;
      }
      const overlapsAnyPath = paths.some((pathEl) => samplePoints(pathEl).some((point) => pointInBox(point, textBox)));
      if (overlapsAnyPath) {
        issues.push({ type: 'text-path-overlap', severity: 'warn', svg: svgIndex, text: textEl.textContent });
      }
    });

    const componentBoxes = [...contentNodes, ...icons]
      .filter((n) => !svgArea || areaOf(n.box) <= svgArea * CONTAINER_AREA_RATIO)
      .map((n) => n.box);
    paths.forEach((pathEl) => {
      const end = endPoint(pathEl);
      if (!end || Number.isNaN(end.x) || Number.isNaN(end.y)) {
        return;
      }
      const landed = componentBoxes.some((box) => pointInBox(end, box, PATH_END_MARGIN));
      if (!landed) {
        issues.push({ type: 'dangling-path-end', severity: 'error', svg: svgIndex, endX: end.x, endY: end.y });
      }
    });

    const usedClasses = new Set();
    svg.querySelectorAll('[class]').forEach((el) => el.classList.forEach((c) => usedClasses.add(c)));
    const definedClasses = findDefinedClasses();
    usedClasses.forEach((c) => {
      if (!definedClasses.has(c)) {
        issues.push({ type: 'undefined-class', severity: 'error', svg: svgIndex, class: c });
      }
    });

    // 文字を載せている器を DOM の入れ子ではなく幾何で選ぶ（<g> でラップしていない文字も対象に入り、入れ子の箱では内側のピルが相手になる）。
    const measureAgainstNodes = (textBox) => {
      let container = null;
      let spilled = null;
      const textArea = areaOf(textBox);
      contentNodes.forEach(({ box }) => {
        const pad = innerPadding(textBox, box);
        if (pad >= -CENTER_TOLERANCE) {
          if (!container || areaOf(box) < areaOf(container.box)) {
            container = { box, pad };
          }
          return;
        }
        if (!boxesIntersect(textBox, box)) {
          return;
        }
        const overlapWidth = Math.min(textBox.x + textBox.width, box.x + box.width) - Math.max(textBox.x, box.x);
        const overlapHeight = Math.min(textBox.y + textBox.height, box.y + box.height) - Math.max(textBox.y, box.y);
        const ratio = textArea ? (overlapWidth * overlapHeight) / textArea : 0;
        if (ratio >= MIN_SPILL_RATIO && (!spilled || ratio > spilled.ratio)) {
          spilled = { ratio, overflow: -pad };
        }
      });
      return { container, spilled };
    };

    texts.forEach((textEl) => {
      const textBox = boxOf(textEl);
      if (!textBox) {
        return;
      }
      const { container, spilled } = measureAgainstNodes(textBox);
      if (spilled) {
        issues.push({
          type: 'text-overflows-parent-rect',
          severity: 'error',
          svg: svgIndex,
          text: textEl.textContent,
          overflow: Math.round(spilled.overflow),
        });
        return;
      }
      if (container && container.pad < MIN_TEXT_PAD) {
        issues.push({
          type: 'tight-text-padding',
          severity: 'warn',
          svg: svgIndex,
          text: textEl.textContent,
          pad: Math.round(container.pad),
          min: Math.round(MIN_TEXT_PAD),
        });
      }
    });

    texts.forEach((textEl) => {
      const textBox = boxOf(textEl);
      if (!textBox) {
        return;
      }
      icons.forEach(({ el, box }) => {
        const iconHref = el.getAttribute('href') || el.getAttribute('xlink:href');
        if (boxesIntersect(textBox, box)) {
          issues.push({
            type: 'text-icon-overlap',
            severity: 'error',
            svg: svgIndex,
            text: textEl.textContent,
            icon: iconHref,
          });
          return;
        }
        const distance = boxDistance(textBox, box);
        if (distance < MIN_ICON_GAP) {
          issues.push({
            type: 'tight-icon-gap',
            severity: 'warn',
            svg: svgIndex,
            text: textEl.textContent,
            icon: iconHref,
            gap: Math.round(distance),
            min: Math.round(MIN_ICON_GAP),
          });
        }
      });
    });

    contentNodes.forEach((a, i) => {
      const boxA = a.box;
      contentNodes.slice(i + 1).forEach((b) => {
        const boxB = b.box;
        const spansX = boxA.x < boxB.x + boxB.width && boxB.x < boxA.x + boxA.width;
        const spansY = boxA.y < boxB.y + boxB.height && boxB.y < boxA.y + boxA.height;
        if (spansX && spansY) {
          return;
        }
        const gaps = [
          { axis: 'x', adjacent: spansY, gap: boxA.x < boxB.x ? boxB.x - (boxA.x + boxA.width) : boxA.x - (boxB.x + boxB.width) },
          { axis: 'y', adjacent: spansX, gap: boxA.y < boxB.y ? boxB.y - (boxA.y + boxA.height) : boxA.y - (boxB.y + boxB.height) },
        ];
        gaps.forEach(({ axis, adjacent, gap }) => {
          if (adjacent && gap >= 0 && gap < MIN_NODE_GAP) {
            issues.push({
              type: 'tight-node-gap',
              severity: 'warn',
              svg: svgIndex,
              axis,
              gap: Math.round(gap),
              min: Math.round(MIN_NODE_GAP),
            });
          }
        });
      });
    });

    borders.forEach(({ el, box }) => {
      const strokeWidth = parseFloat(getComputedStyle(el).strokeWidth) || 1;
      const outer = {
        x: box.x - strokeWidth,
        y: box.y - strokeWidth,
        width: box.width + strokeWidth * 2,
        height: box.height + strokeWidth * 2,
      };
      const inner = {
        x: box.x + strokeWidth,
        y: box.y + strokeWidth,
        width: Math.max(0, box.width - strokeWidth * 2),
        height: Math.max(0, box.height - strokeWidth * 2),
      };
      texts.forEach((textEl) => {
        const textBox = boxOf(textEl);
        if (!textBox) {
          return;
        }
        const insideOuter = boxesIntersect(textBox, outer);
        if (insideOuter && innerPadding(textBox, inner) < 0) {
          issues.push({ type: 'text-groupborder-overlap', severity: 'warn', svg: svgIndex, text: textEl.textContent });
          return;
        }
        const distance = insideOuter ? innerPadding(textBox, inner) : boxDistance(textBox, outer);
        if (distance < MIN_TEXT_PAD) {
          issues.push({
            type: 'tight-groupborder-padding',
            severity: 'warn',
            svg: svgIndex,
            text: textEl.textContent,
            gap: Math.round(distance),
            min: Math.round(MIN_TEXT_PAD),
          });
        }
      });
    });

    const gaps = horizontalGaps(svg);
    const isNarrowerThanWrapper = gaps !== null && gaps.left + gaps.right > CENTER_TOLERANCE;
    if (isNarrowerThanWrapper && Math.abs(gaps.left - gaps.right) > CENTER_TOLERANCE) {
      issues.push({
        type: 'svg-not-centered',
        severity: 'error',
        svg: svgIndex,
        left: Math.round(gaps.left),
        right: Math.round(gaps.right),
      });
    }
  });

  return issues;
};
