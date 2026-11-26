/* 账本助手 mascot drafts: three characters drawn on one 64-unit grid.
 * Mascot.svg(kind, opts) -> SVG string.
 *   kind:   'bean' (豆豆) | 'book' (本本) | 'cat' (团子)
 *   opts.state:  idle | thinking | tool | success | error
 *   opts.dark:   night colours
 *   opts.mono:   one-colour glyph (tab bar, Live Activity, notifications);
 *                opts.ink / opts.ground colour it
 *   opts.small:  detail for 16–28pt (drops sheen, whiskers, label, props shrink)
 *   opts.anim:   CSS motion (blink, breath, per-state loop)
 *   opts.px:     rendered size
 */
(function (root) {
  let uid = 0;

  const PAL = {
    bean: {
      light: { line: '#3B2A1E', body: '#EFC48E', shade: '#DDA46A', hilum: '#F8E2BF', cheek: '#F2A08E', leaf: '#7FAE6A', leafDark: '#5F8F4E', eye: '#2A1D14', hi: '#FFFFFF', petal: '#F6B7C3', prop: '#9CC9E6' },
      dark:  { line: '#24180F', body: '#E3B47E', shade: '#C98F57', hilum: '#F2D6AE', cheek: '#E58C7A', leaf: '#86B872', leafDark: '#5F8F4E', eye: '#21160E', hi: '#FFFFFF', petal: '#F0A7B5', prop: '#8FC0E0', aux: '#C9BBA8' },
    },
    book: {
      light: { line: '#2A3236', body: '#F8F0E1', shade: '#EADCC2', spine: '#3E5B63', fold: '#D9A447', ribbon: '#E07A5F', cheek: '#F2A08E', eye: '#22292C', hi: '#FFFFFF', label: '#C9B99A', prop: '#F2C14E' },
      dark:  { line: '#161C1F', body: '#EFE5D2', shade: '#D9C8AA', spine: '#4D6E77', fold: '#DFAA4E', ribbon: '#E58468', cheek: '#E58C7A', eye: '#1A2023', hi: '#FFFFFF', label: '#BCAA88', prop: '#F2C14E', aux: '#B9C2C6' },
    },
    cat: {
      light: { line: '#3A2A20', body: '#FFF6EA', shade: '#F0E2CD', patch: '#EFA65C', inner: '#F6B4A6', nose: '#E8877A', cheek: '#F6A99A', eye: '#2A1E16', hi: '#FFFFFF', prop: '#E6B84A', glass: '#9CC9E6', aux: '#3A2A20' },
      dark:  { line: '#21170F', body: '#F6EBDC', shade: '#E2CFB6', patch: '#E89A4E', inner: '#EFA596', nose: '#DE7C6F', cheek: '#EE9A8B', eye: '#20160F', hi: '#FFFFFF', prop: '#E3B246', glass: '#8FC0E0', aux: '#C9BBA8' },
    },
  };

  function monoPal(ink, ground) {
    const p = {};
    for (const k of ['line', 'body', 'shade', 'hilum', 'leaf', 'leafDark', 'spine', 'fold', 'ribbon', 'patch', 'inner', 'nose', 'prop', 'glass', 'petal', 'label', 'aux'])
      p[k] = ink;
    p.eye = ground; p.hi = 'none'; p.cheek = 'none';
    return p;
  }

  // ---------- shared face parts ----------
  function eyes(state, lx, rx, y, p, o) {
    const sw = o.small ? 2.3 : 1.8;
    if (state === 'success') {
      const arc = x => `<path d="M${x - 2.5} ${y + 1.1}Q${x} ${y - 2.8} ${x + 2.5} ${y + 1.1}" fill="none" stroke="${p.eye}" stroke-width="${sw}" stroke-linecap="round"/>`;
      return arc(lx) + arc(rx);
    }
    let dx = 0, dy = 0, rx_ = 2.15, ry_ = 2.75;
    if (state === 'thinking') { dx = 0.9; dy = -0.9; }
    if (state === 'tool') { dx = 0.7; dy = 0.5; }
    if (state === 'error') { rx_ = 1.8; ry_ = 2.2; dy = 0.4; }
    if (o.small) { rx_ += 0.45; ry_ += 0.35; }
    const one = x => `<ellipse cx="${x + dx}" cy="${y + dy}" rx="${rx_}" ry="${ry_}" fill="${p.eye}"/>` +
      (o.small || p.hi === 'none' ? '' : `<circle cx="${x + dx + 0.75}" cy="${y + dy - 1.05}" r="0.8" fill="${p.hi}"/>`);
    let s = `<g class="m-eyes">${one(lx)}${one(rx)}</g>`;
    if (state === 'error' && !o.small) {
      s += `<path d="M${lx - 2.8} ${y - 4.2}L${lx + 1.6} ${y - 5.8}M${rx + 2.8} ${y - 4.2}L${rx - 1.6} ${y - 5.8}" stroke="${p.eye}" stroke-width="1.3" stroke-linecap="round"/>`;
    }
    return s;
  }

  function mouth(state, cx, y, p, o) {
    const sw = o.small ? 1.9 : 1.4;
    const st = `fill="none" stroke="${p.eye}" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round"`;
    switch (state) {
      case 'thinking': return `<path d="M${cx - 1.1} ${y + 0.9}Q${cx + 0.2} ${y + 0.2} ${cx + 1.4} ${y + 0.5}" ${st}/>`;
      case 'tool': return `<path d="M${cx - 1.3} ${y + 0.4}Q${cx} ${y + 1.3} ${cx + 1.3} ${y + 0.4}" ${st}/>` +
        (o.small ? '' : `<path d="M${cx + 0.2} ${y + 0.9}q0.7 1.4 1.5 0.2" fill="${p.cheek === 'none' ? p.eye : '#E8877A'}" stroke="none"/>`);
      case 'success': return `<path d="M${cx - 2.7} ${y - 0.4}Q${cx} ${y + 4.2} ${cx + 2.7} ${y - 0.4}Z" fill="${p.eye}" stroke="${p.eye}" stroke-width="0.8" stroke-linejoin="round"/>` +
        (o.small || p.cheek === 'none' ? '' : `<path d="M${cx - 1.3} ${y + 1.75}Q${cx} ${y + 0.9} ${cx + 1.3} ${y + 1.75}Q${cx} ${y + 2.9} ${cx - 1.3} ${y + 1.75}Z" fill="#E8877A"/>`);
      case 'error': return `<path d="M${cx - 2.4} ${y + 1.2}q0.6 -1.1 1.2 0t1.2 0t1.2 0t1.2 0" ${st}/>`;
      default: return `<path d="M${cx - 1.7} ${y}Q${cx} ${y + 1.9} ${cx + 1.7} ${y}" ${st}/>`;
    }
  }

  function cheeks(lx, rx, y, p, o) {
    if (p.cheek === 'none') return '';
    const r = o.small ? [3.1, 2] : [2.9, 1.7];
    return `<g opacity="0.75"><ellipse cx="${lx}" cy="${y}" rx="${r[0]}" ry="${r[1]}" fill="${p.cheek}"/><ellipse cx="${rx}" cy="${y}" rx="${r[0]}" ry="${r[1]}" fill="${p.cheek}"/></g>`;
  }

  function sweat(x, y, p, sc = 1) {
    return `<path class="m-sweat" d="M${x} ${y}C${x - 1.8 * sc} ${y + 2.8 * sc} ${x - 1.8 * sc} ${y + 4.6 * sc} ${x} ${y + 4.6 * sc}C${x + 1.8 * sc} ${y + 4.6 * sc} ${x + 1.8 * sc} ${y + 2.8 * sc} ${x} ${y}Z" fill="${p.prop === p.line ? p.line : '#9FD0EE'}" stroke="${p.line}" stroke-width="0.9" stroke-linejoin="round"/>`;
  }

  function star(x, y, r, fill) {
    const k = r * 0.28;
    return `<path d="M${x} ${y - r}Q${x + k} ${y - k} ${x + r} ${y}Q${x + k} ${y + k} ${x} ${y + r}Q${x - k} ${y + k} ${x - r} ${y}Q${x - k} ${y - k} ${x} ${y - r}Z" fill="${fill}"/>`;
  }

  function sparkles(p, pts) {
    const c = p.cheek === 'none' ? p.line : '#F2B84B';
    return `<g class="m-spark">${pts.map(([x, y, r]) => star(x, y, r, c)).join('')}</g>`;
  }

  function thoughtDots(p, pts) {
    return `<g class="m-dots">${pts.map(([x, y, r], i) => `<circle class="d${i}" cx="${x}" cy="${y}" r="${r}" fill="${p.aux}"/>`).join('')}</g>`;
  }

  // ---------- 豆豆: a Beancount bean with a sprout ----------
  function bean(state, p, o, id) {
    const LW = o.small ? 2.6 : 2;
    const bodyD = 'M32 18.5C44.5 18.5 51.5 26.5 51.5 37.5C51.5 49.5 43.5 56 32 56C20.5 56 12.5 50 12.5 44C12.5 40.4 15.6 38.8 15.6 35.4C15.6 32.2 13.6 30.4 14.4 27C16.4 21.4 23.5 18.5 32 18.5Z';
    let s = '';
    // feet
    s += `<g fill="${p.shade}" stroke="${p.line}" stroke-width="${LW}"><ellipse cx="25.5" cy="56" rx="4" ry="2.4"/><ellipse cx="38" cy="56" rx="4" ry="2.4"/></g>`;
    // sprout
    const leafL = 'M32.6 12.6C29.6 7.4 25.2 6.6 22.6 8.4C24.6 12.4 28.8 13.8 32.6 12.6Z';
    const leafR = 'M32.6 12.6C35.4 6.6 40.6 5.6 43.4 7.6C41 12.2 36.4 13.8 32.6 12.6Z';
    let lt = '', rt = '', st = '';
    if (state === 'error') { lt = 'rotate(-62 32.6 12.6)'; rt = 'rotate(58 32.6 12.6)'; st = 'rotate(14 32 19)'; }
    if (state === 'success') { lt = 'rotate(-8 32.6 12.6)'; rt = 'rotate(8 32.6 12.6)'; }
    s += `<g class="m-sprout" transform="${st}">` +
      `<path d="M32 19.5C32 16.6 32.4 14.4 32.6 12.6" fill="none" stroke="${p.line}" stroke-width="${LW + 0.4}" stroke-linecap="round"/>` +
      `<path d="M32 19.5C32 16.6 32.4 14.4 32.6 12.6" fill="none" stroke="${p.leafDark}" stroke-width="${LW - 1}" stroke-linecap="round"/>` +
      `<g class="m-leaf-l" transform="${lt}"><path d="${leafL}" fill="${p.leaf}" stroke="${p.line}" stroke-width="${LW * 0.85}" stroke-linejoin="round"/>${o.small ? '' : `<path d="M31 12.2Q27.5 10.3 25 9.4" stroke="${p.leafDark}" stroke-width="0.9" fill="none" stroke-linecap="round"/>`}</g>` +
      `<g class="m-leaf-r" transform="${rt}"><path d="${leafR}" fill="${p.leaf}" stroke="${p.line}" stroke-width="${LW * 0.85}" stroke-linejoin="round"/>${o.small ? '' : `<path d="M34.2 12Q37.8 9.6 41 8.6" stroke="${p.leafDark}" stroke-width="0.9" fill="none" stroke-linecap="round"/>`}</g>`;
    if (state === 'success' && !o.small) {
      // a bud opens between the leaves
      const pc = p.petal;
      s += `<g class="m-bloom">${[0, 72, 144, 216, 288].map(a => `<ellipse cx="32.6" cy="8.6" rx="1.7" ry="2.5" fill="${pc}" stroke="${p.line}" stroke-width="0.8" transform="rotate(${a} 32.6 11.2)"/>`).join('')}<circle cx="32.6" cy="11.2" r="1.5" fill="#F7D36B" stroke="${p.line}" stroke-width="0.8"/></g>`;
    }
    s += `</g>`;
    // body
    s += `<g class="m-body">`;
    s += `<clipPath id="bc${id}"><path d="${bodyD}"/></clipPath>`;
    s += `<path d="${bodyD}" fill="${p.body}"/>`;
    if (o.mono) s += `<path d="M16.4 31.6Q18.2 35.2 16.8 38.8" fill="none" stroke="${p.eye}" stroke-width="1.8" stroke-linecap="round"/>`;
    if (!o.mono) {
      s += `<g clip-path="url(#bc${id})"><path d="M10 47C20 55 40 56 54 41V60H10Z" fill="${p.shade}" opacity="0.55"/></g>`;
      if (!o.small) {
        s += `<path d="M22.5 24.6C25 22.4 28 21.6 30.6 21.5" fill="none" stroke="#FFFFFF" stroke-opacity="0.75" stroke-width="1.8" stroke-linecap="round"/>`;
        s += `<path d="M17.2 31.4Q18.7 35.2 17.5 38.6" fill="none" stroke="${p.hilum}" stroke-width="2" stroke-linecap="round"/>`;
      }
    }
    s += `<path d="${bodyD}" fill="none" stroke="${p.line}" stroke-width="${LW}" stroke-linejoin="round"/>`;
    // face
    s += cheeks(24.6, 43.4, 42.6, p, o);
    s += `<g class="m-face">${eyes(state, 28, 38.6, 37.4, p, o)}${mouth(state, 33.3, 41.6, p, o)}</g>`;
    s += `</g>`;
    // props
    if (state === 'tool') {
      s += `<g class="m-tool">` +
        `<path d="M46.4 43.6L50.6 38.6" stroke="${p.line}" stroke-width="${o.small ? 3.6 : 3}" stroke-linecap="round"/>` +
        `<circle cx="53.2" cy="34.8" r="${o.small ? 5 : 4.8}" fill="${o.mono ? p.eye : p.prop}" fill-opacity="${o.mono ? 1 : 0.45}" stroke="${p.line}" stroke-width="${LW}"/>` +
        (o.small || o.mono ? '' : `<path d="M50.8 33.4Q51.6 31.6 53.4 31.2" stroke="#FFFFFF" stroke-width="1.2" fill="none" stroke-linecap="round"/>`) +
        `<ellipse cx="47.6" cy="44.4" rx="3.2" ry="2.5" fill="${p.body}" stroke="${p.line}" stroke-width="${LW}" transform="rotate(-35 47.6 44.4)"/></g>`;
    }
    if (state === 'thinking') s += thoughtDots(p, o.small ? [[50, 17, 2.2], [56, 11, 2.6]] : [[48.6, 19.4, 1.4], [52.6, 14.6, 1.9], [57.4, 9.4, 2.5]]);
    if (state === 'success' && !o.small) s += sparkles(p, [[9, 20, 3.2], [55.5, 17, 2.4], [57, 46, 2]]);
    if (state === 'error') s += sweat(o.small ? 49 : 48.5, o.small ? 20 : 21.5, p, o.small ? 1.25 : 1);
    return s;
  }

  // ---------- 本本: a little ledger notebook ----------
  function book(state, p, o, id) {
    const LW = o.small ? 2.6 : 2;
    const bodyD = 'M21 13H41.5L50 21.5V51Q50 56 45 56H21Q15.5 56 15.5 50.5V18.5Q15.5 13 21 13Z';
    let s = '';
    // ribbon tail and feet
    s += `<g class="m-ribbon"><path d="M42.2 54V62.4L44.3 60.4L46.4 62.4V54Z" fill="${p.ribbon}" stroke="${p.line}" stroke-width="${LW * 0.8}" stroke-linejoin="round"/></g>`;
    s += `<g fill="${p.shade}" stroke="${p.line}" stroke-width="${LW}"><ellipse cx="25.5" cy="56.2" rx="3.6" ry="2.2"/><ellipse cx="35.5" cy="56.2" rx="3.6" ry="2.2"/></g>`;
    if (state === 'success') {
      s += `<g fill="${p.body}" stroke="${p.line}" stroke-width="${LW}"><ellipse cx="14" cy="30" rx="3.2" ry="2.5" transform="rotate(-55 14 30)"/><ellipse cx="51.4" cy="33" rx="3.2" ry="2.5" transform="rotate(55 51.4 33)"/></g>`;
    }
    s += `<g class="m-body">`;
    s += `<clipPath id="kc${id}"><path d="${bodyD}"/></clipPath>`;
    s += `<path d="${bodyD}" fill="${p.body}"/>`;
    s += `<g clip-path="url(#kc${id})">`;
    s += `<rect x="14" y="12" width="7.6" height="46" fill="${p.spine}"/>`;
    if (!o.mono) {
      s += `<path d="M21.6 50H52V58H21.6Z" fill="${p.shade}" opacity="0.6"/>`;
      if (!o.small) s += `<path d="M17.2 18V51" stroke="#FFFFFF" stroke-opacity="0.22" stroke-width="1.4" stroke-linecap="round"/>`;
    }
    s += `</g>`;
    s += `<path d="M21.6 13.4V55.6" stroke="${o.mono ? p.eye : p.line}" stroke-width="${LW * 0.7}"/>`;
    if (!o.small && !o.mono) {
      s += `<rect x="27.6" y="18.2" width="13.6" height="6" rx="1.6" fill="none" stroke="${p.label}" stroke-width="1.1"/>` +
        `<path d="M30.4 21.2H38.4" stroke="${p.label}" stroke-width="1.1" stroke-linecap="round"/>`;
    }
    if (state === 'error' && !o.small) {
      s += `<path d="M24.4 46.4C23.2 45 24.6 43.4 26 44.2C26.6 42.6 29 43 28.8 44.8C30.4 45 30.4 47.4 28.8 47.6C29.4 49.4 27 50.2 26.2 48.8C24.8 49.8 23 48 24.4 46.4Z" fill="${p.line}" opacity="0.85"/><circle cx="31" cy="49.4" r="0.9" fill="${p.line}" opacity="0.85"/>`;
    }
    s += `<path d="${bodyD}" fill="none" stroke="${p.line}" stroke-width="${LW}" stroke-linejoin="round"/>`;
    // the turned corner, as on today's mark
    const foldT = state === 'thinking' ? 'rotate(-26 41.5 21.5)' : '';
    s += `<g class="m-fold" transform="${foldT}"><path d="M41.5 13V19.2Q41.5 21.5 43.8 21.5H50Z" fill="${p.fold}" stroke="${o.mono ? p.eye : p.line}" stroke-width="${LW * 0.85}" stroke-linejoin="round"/></g>`;
    s += cheeks(28.4, 44, 41.4, p, o);
    s += `<g class="m-face">${eyes(state, 31.4, 41.2, 35.6, p, o)}${mouth(state, 36.3, 39.8, p, o)}</g>`;
    s += `</g>`;
    if (state === 'tool') {
      // writing with a pencil
      s += `<g class="m-tool">` +
        `<g transform="rotate(35 53 40)"><rect x="50.8" y="27" width="4.4" height="15" rx="1" fill="${o.mono ? p.line : p.prop}" stroke="${p.line}" stroke-width="${LW * 0.8}"/>` +
        `<path d="M50.8 42L53 46.6L55.2 42Z" fill="${o.mono ? p.line : '#F3DDB8'}" stroke="${p.line}" stroke-width="${LW * 0.8}" stroke-linejoin="round"/>` +
        (o.mono ? '' : `<rect x="50.8" y="25.2" width="4.4" height="2.6" rx="1" fill="#F2A3A3" stroke="${p.line}" stroke-width="${LW * 0.8}"/>`) + `</g>` +
        `<ellipse cx="49.4" cy="41.6" rx="3" ry="2.4" fill="${p.body}" stroke="${p.line}" stroke-width="${LW}"/></g>`;
    }
    if (state === 'thinking') s += thoughtDots(p, o.small ? [[55, 13, 2.2], [59.4, 7, 2.6]] : [[54.6, 15, 1.4], [57.6, 10, 1.9], [61, 4.6, 2.4]]);
    if (state === 'success' && !o.small) s += sparkles(p, [[8.6, 18, 3], [56.4, 13, 2.4], [58, 47, 2]]);
    if (state === 'error') s += sweat(o.small ? 11 : 10.6, o.small ? 18 : 19, p, o.small ? 1.25 : 1);
    return s;
  }

  // ---------- 团子: a loaf cat ----------
  function cat(state, p, o, id) {
    const LW = o.small ? 2.6 : 2;
    const bodyD = 'M11 52.6C11 37.4 18.4 26.6 32 26.6C45.6 26.6 53 37.4 53 52.6Q53 56 49.6 56H14.4Q11 56 11 52.6Z';
    let s = '';
    // tail, behind
    const tailT = state === 'success' ? 'rotate(-18 50 52)' : '';
    s += `<g class="m-tail" transform="${tailT}"><path d="M48 53.4C55 53.8 58.8 49 57.4 43.6C56.6 40.6 54 40 53 41.8" fill="none" stroke="${p.line}" stroke-width="${o.small ? 7.6 : 6.6}" stroke-linecap="round"/>` +
      `<path d="M48 53.4C55 53.8 58.8 49 57.4 43.6C56.6 40.6 54 40 53 41.8" fill="none" stroke="${p.patch}" stroke-width="${o.small ? 3.6 : 3.2}" stroke-linecap="round"/></g>`;
    // ears, behind the head
    let el = '', er = '';
        if (state === 'thinking') { er = 'rotate(16 43 31)'; }
    const earL = 'M15.2 35.2L16.6 17.8Q17.4 15 19.8 16.6L31 27.6Z';
    const earR = 'M48.8 35.2L47.4 17.8Q46.6 15 44.2 16.6L33 27.6Z';
    if (state === 'error') {
      // 飞机耳: ears pressed flat out to the sides
      const fl = 'M22.6 29.4L9.2 25.2Q6.6 24.8 7.6 27.4L14.6 37.4Z', fr = 'M41.4 29.4L54.8 25.2Q57.4 24.8 56.4 27.4L49.4 37.4Z';
      s += `<g class="m-ear-l"><path d="${fl}" fill="${p.patch}" stroke="${p.line}" stroke-width="${LW}" stroke-linejoin="round"/>${o.small || o.mono ? '' : `<path d="M18.6 30.2L11.6 27.6L15 33.6Z" fill="${p.inner}"/>`}</g>`;
      s += `<g class="m-ear-r"><path d="${fr}" fill="${p.patch}" stroke="${p.line}" stroke-width="${LW}" stroke-linejoin="round"/>${o.small || o.mono ? '' : `<path d="M45.4 30.2L52.4 27.6L49 33.6Z" fill="${p.inner}"/>`}</g>`;
    } else {
    s += `<g class="m-ear-l" transform="${el}"><path d="${earL}" fill="${p.patch}" stroke="${p.line}" stroke-width="${LW}" stroke-linejoin="round"/>${o.small || o.mono ? '' : `<path d="M19 29.6L19.6 21.4L25.6 27.4Z" fill="${p.inner}"/>`}</g>`;
    s += `<g class="m-ear-r" transform="${er}"><path d="${earR}" fill="${p.patch}" stroke="${p.line}" stroke-width="${LW}" stroke-linejoin="round"/>${o.small || o.mono ? '' : `<path d="M45 29.6L44.4 21.4L38.4 27.4Z" fill="${p.inner}"/>`}</g>`;
    }
    s += `<g class="m-body">`;
    s += `<clipPath id="cc${id}"><path d="${bodyD}"/></clipPath>`;
    s += `<path d="${bodyD}" fill="${p.body}"/>`;
    if (!o.mono) {
      s += `<g clip-path="url(#cc${id})">` +
        `<path d="M14 30C20 25 44 25 50 30C46 34.4 40.4 32.4 38.4 36C36.6 33.2 27.4 33.2 25.6 36C23.6 32.4 18 34.4 14 30Z" fill="${p.patch}"/>` +
        `<path d="M8 50C22 57 42 57 56 50V60H8Z" fill="${p.shade}" opacity="0.7"/>` +
        `</g>`;
      if (!o.small) s += `<path d="M29.6 28.4V31.4M32 28V31.6M34.4 28.4V31.4" stroke="${p.line}" stroke-opacity="0.35" stroke-width="1.1" stroke-linecap="round"/>`;
    }
    s += `<path d="${bodyD}" fill="none" stroke="${p.line}" stroke-width="${LW}" stroke-linejoin="round"/>`;
    s += cheeks(21.4, 42.6, 45.6, p, o);
    // face
    let face = eyes(state, 25.6, 38.4, 41, p, o);
    face += `<path d="M30.8 43.7H33.2L32 45.1Z" fill="${p.nose}" stroke="${p.nose}" stroke-width="0.9" stroke-linejoin="round"/>`;
    if (state === 'success' || state === 'error' || state === 'thinking') face += mouth(state, 32, 45.4, p, o);
    else face += `<path d="M29.5 45.6Q30.75 47.4 32 45.6Q33.25 47.4 34.5 45.6" fill="none" stroke="${p.eye}" stroke-width="${o.small ? 1.9 : 1.3}" stroke-linecap="round" stroke-linejoin="round"/>`;
    if (!o.small && !o.mono) {
      face += `<path d="M14.6 42.6L19.6 43.6M14.8 46.4L19.6 45.6M49.4 42.6L44.4 43.6M49.2 46.4L44.4 45.6" stroke="${p.line}" stroke-opacity="0.45" stroke-width="1" stroke-linecap="round"/>`;
    }
    if (state === 'tool') {
      // round reading glasses: checking the books
      face += `<g class="m-glasses" fill="${o.mono ? 'none' : p.glass}" fill-opacity="0.22" stroke="${p.line}" stroke-width="${o.small ? 2 : 1.5}">` +
        `<circle cx="25.6" cy="41.2" r="${o.small ? 5 : 4.8}"/><circle cx="38.4" cy="41.2" r="${o.small ? 5 : 4.8}"/><path d="M30.4 40.6Q32 39.4 33.6 40.6" fill="none"/></g>` +
        (o.small || o.mono ? '' : `<path d="M22.6 39.4L24.4 37.8M35.4 39.4L37.2 37.8" stroke="#FFFFFF" stroke-width="1.1" stroke-linecap="round"/>`);
    }
    s += `<g class="m-face">${face}</g>`;
    s += `</g>`;
    // paws in front
    s += `<g fill="${p.body}" stroke="${p.line}" stroke-width="${LW}"><ellipse cx="25.6" cy="55.6" rx="4" ry="2.6"/><ellipse cx="38.4" cy="55.6" rx="4" ry="2.6"/></g>`;
    if (!o.small && !o.mono) s += `<path d="M24.6 54.6V56.2M26.6 54.6V56.2M37.4 54.6V56.2M39.4 54.6V56.2" stroke="${p.line}" stroke-width="0.8" stroke-linecap="round" opacity="0.6"/>`;
    if (state === 'success') {
      // a copper coin pops up beside it: 招财
      const c = o.mono ? p.line : p.prop, r = o.small ? 6 : 5.4;
      s += `<g class="m-coin"><circle cx="54" cy="21" r="${r}" fill="${c}" stroke="${p.line}" stroke-width="${LW * 0.85}"/>` +
        `<rect x="52" y="19" width="4" height="4" rx="0.6" fill="${o.mono ? p.eye : p.body}" stroke="${o.mono ? 'none' : p.line}" stroke-width="0.9"/>` +
        (o.small || o.mono ? '' : `<path d="M50.6 18.6Q51.4 16.8 53.2 16.2" stroke="#FFFFFF" stroke-width="1" fill="none" stroke-linecap="round"/>`) + `</g>`;
      if (!o.small) s += sparkles(p, [[9, 22, 3], [60, 31, 1.8], [45.6, 13, 2]]);
    }
    if (state === 'thinking') s += thoughtDots(p, o.small ? [[53, 19, 2.2], [58.4, 13, 2.6]] : [[52.6, 21, 1.4], [56, 16, 1.9], [60, 10.4, 2.4]]);
    if (state === 'error') s += sweat(o.small ? 51 : 50.4, o.small ? 24 : 25.4, p, o.small ? 1.25 : 1);
    return s;
  }

  const DRAW = { bean, book, cat };

  function svg(kind, opts = {}) {
    const o = Object.assign({ state: 'idle', dark: false, mono: false, small: false, anim: false, px: 64 }, opts);
    const id = ++uid;
    const p = o.mono ? monoPal(o.ink || '#14100C', o.ground || '#FBFAF8') : PAL[kind][o.dark ? 'dark' : 'light'];
    const cls = `mascot m-${kind} s-${o.state}${o.anim ? ' anim' : ''}${o.small ? ' small' : ''}`;
    const title = { bean: '豆豆', book: '本本', cat: '团子' }[kind];
    return `<svg class="${cls}" viewBox="0 0 64 64" width="${o.px}" height="${o.px}" role="img" aria-label="${title}（${o.state}）" xmlns="http://www.w3.org/2000/svg"><g class="m-all">${DRAW[kind](o.state, p, o, id)}</g></svg>`;
  }

  root.Mascot = { svg, PAL, STATES: ['idle', 'thinking', 'tool', 'success', 'error'] };
})(typeof window !== 'undefined' ? window : globalThis);
