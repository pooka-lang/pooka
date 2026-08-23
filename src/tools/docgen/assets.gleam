//// Keep the reading room's lamps and switches together.
////
//// Ship offline CSS and JavaScript for navigation, search, code copying and
//// light/dark themes. Brand colours adapt to their background so examples remain
//// readable.
////
//// ```text
//// system dark theme -> midnight background + cream text
//// ```

// SPDX-License-Identifier: Apache-2.0

pub const theme_bootstrap =
  "(()=>{document.documentElement.classList.add('js');try{const t=localStorage.getItem('pooka-docs-theme');document.documentElement.dataset.theme=['light','dark'].includes(t)?t:matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light'}catch{document.documentElement.dataset.theme=matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light'}})();"

pub const css =
  "
:root {
  color-scheme: light;
  --midnight: #211c1b; --lantern-orange: #ff891f; --amber-glow: #ffb64b;
  --scarf: #d95b17; --cream: #fff6e9; --ember-brown: #79452f;
  --forest: #30463d; --magic-violet: #75618e;
  --bg: var(--cream); --sidebar: #f6ebdc; --surface: #fffaf3; --soft: #f1e4d5;
  --ink: var(--midnight); --text: #49392f; --muted: #75645a; --border: #decebc;
  --accent: var(--ember-brown); --accent-soft: #ffe3bd; --code: #f5eadc;
  --keyword: #a54210; --string: var(--forest); --number: var(--ember-brown); --type: var(--magic-violet);
  --shadow: 0 12px 35px #211c1b10; --sidebar-width: 300px;
}
:root[data-theme='dark'] {
  color-scheme: dark;
  --bg: var(--midnight); --sidebar: #1b1716; --surface: #2b2422; --soft: #352b26;
  --ink: var(--cream); --text: #e8dcd0; --muted: #b9aaa0; --border: #493a32;
  --accent: var(--lantern-orange); --accent-soft: #3d2c20; --code: #1b1716;
  --keyword: var(--amber-glow); --string: #b9c7bd; --number: var(--lantern-orange); --type: #c3afd2;
  --shadow: 0 12px 35px #0002;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme]) {
    color-scheme: dark;
    --bg: var(--midnight); --sidebar: #1b1716; --surface: #2b2422; --soft: #352b26;
    --ink: var(--cream); --text: #e8dcd0; --muted: #b9aaa0; --border: #493a32;
    --accent: var(--lantern-orange); --accent-soft: #3d2c20; --code: #1b1716;
    --keyword: var(--amber-glow); --string: #b9c7bd; --number: var(--lantern-orange); --type: #c3afd2;
    --shadow: 0 12px 35px #0002;
  }
}
* { box-sizing: border-box; }
[hidden] { display: none !important; }
html { scroll-behavior: smooth; scroll-padding-top: 90px; }
body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.75 ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; -webkit-font-smoothing: antialiased; }
a { color: var(--accent); text-underline-offset: 3px; }
a:hover { text-decoration: underline; }
button, input { font: inherit; }
button { cursor: pointer; }
button, input, a { -webkit-tap-highlight-color: transparent; }
:focus-visible { outline: 3px solid var(--lantern-orange); outline-offset: 4px; border-radius: 3px; }
::selection { background: var(--accent-soft); color: var(--ink); }
.sr-only { position: absolute; width: 1px; height: 1px; padding: 0; overflow: hidden; clip: rect(0,0,0,0); white-space: nowrap; border: 0; }
.skip-link { position: fixed; left: 16px; top: -80px; z-index: 30; padding: 8px 16px; background: var(--ink); color: var(--bg); }
.skip-link:focus { top: 12px; }
.sidebar { position: fixed; inset: 0 auto 0 0; width: var(--sidebar-width); display: flex; flex-direction: column; background: var(--sidebar); border-right: 1px solid var(--border); z-index: 12; }
.project-heading { padding: 26px 25px 21px; }
.project-heading > a { color: var(--ink); font-size: 25px; font-weight: 700; letter-spacing: -.6px; line-height: 1.3; text-decoration: none; overflow-wrap: anywhere; }
.project-meta { display: flex; align-items: center; gap: 9px; margin-top: 8px; color: var(--muted); font-size: 12px; }
.version { font: 11px/1.5 ui-monospace, monospace; padding: 2px 7px; border: 1px solid var(--border); border-radius: 5px; color: var(--muted); }
.project-meta [data-doc-version] { min-width: 0; }
.version-select { max-width: min(170px, 100%); background: var(--bg); color: var(--ink); cursor: pointer; }
.version-select:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }
.version-select option { background: var(--bg); color: var(--ink); }
.search { position: relative; margin: 0 19px 17px; }
.search input { width: 100%; padding: 9px 31px 9px 34px; border-radius: 7px; border: 1px solid var(--border); background: var(--bg); color: var(--ink); font-size: 13px; outline-offset: 2px; }
.search svg { position: absolute; width: 15px; height: 15px; left: 11px; top: 13px; color: var(--muted); pointer-events: none; }
.search kbd { position: absolute; right: 10px; top: 10px; color: var(--muted); font: 12px/1.5 ui-monospace,monospace; pointer-events: none; }
.nav-scroll { overflow-y: auto; overscroll-behavior: contain; flex: 1; padding: 0 15px 24px; scrollbar-width: thin; }
.nav-label { margin: 20px 11px 7px; color: var(--muted); font-size: 10px; font-weight: 750; letter-spacing: 1.8px; text-transform: uppercase; }
.page-link, .module-link { font-size: 15px; text-decoration: none; color: var(--text); }
.page-link { display: flex; gap: 9px; align-items: center; padding: 7px 11px; border-radius: 5px; }
.page-link[aria-current='page'] { background: var(--accent-soft); color: var(--accent); font-weight: 650; }
.module-tree { margin: 3px 0; }
.module-tree > summary { display: flex; align-items: center; gap: 7px; list-style: none; border-radius: 5px; cursor: pointer; padding: 5px 9px; }
.module-tree > summary::-webkit-details-marker { display: none; }
.module-tree > summary::before { content: '›'; font-size: 16px; color: var(--muted); width: 10px; transform: rotate(0); transition: transform .12s; }
.module-tree[open] > summary::before { transform: rotate(90deg); }
.module-tree[data-current] > summary { background: var(--accent-soft); }
.module-tree[data-current] .module-link { font-weight: 700; color: var(--accent); }
.module-link { display: block; flex: 1; min-width: 0; overflow-wrap: anywhere; font-family: ui-monospace, SFMono-Regular, Consolas, monospace; }
.module-count { color: var(--muted); font: 10px ui-monospace,monospace; }
.module-symbols { margin: 7px 0 12px 21px; padding-left: 8px; border-left: 1px solid var(--border); }
.symbol-group { margin: 12px 0 6px 8px; color: var(--muted); font-size: 11px; font-weight: 750; letter-spacing: 1.2px; text-transform: uppercase; }
.symbol-list, .symbol-children { padding: 0; margin: 0; list-style: none; }
.symbol-link { display: flex; gap: 8px; align-items: baseline; padding: 4px 8px; color: var(--text); font: 14px/1.65 ui-monospace, SFMono-Regular, Consolas, monospace; border-radius: 4px; text-decoration: none; overflow-wrap: anywhere; }
.symbol-link:hover, .symbol-link[aria-current='location'] { background: var(--soft); color: var(--accent); text-decoration: none; }
.symbol-icon { width: 13px; flex: none; color: var(--muted); font-size: 9px; font-family: ui-sans-serif,system-ui,sans-serif; font-weight: 750; }
.symbol-children { padding-left: 20px; }
.symbol-children .symbol-link { font-size: 13px; color: var(--muted); }
.nav-empty { margin: 14px 12px; color: var(--muted); font-size: 12px; }
.topbar { position: sticky; top: 0; height: 66px; margin-left: var(--sidebar-width); padding: 0 42px; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--border); background: var(--bg); z-index: 5; }
.breadcrumb { display: flex; gap: 10px; align-items: center; min-width: 0; color: var(--muted); font-size: 12px; }
.breadcrumb strong { font-weight: 550; color: var(--ink); overflow-wrap: anywhere; }
.top-actions { display: flex; gap: 8px; align-items: center; }
.theme-toggle, .menu-toggle { display: inline-flex; align-items: center; justify-content: center; gap: 7px; padding: 6px 9px; border: 1px solid var(--border); border-radius: 6px; background: var(--surface); color: var(--muted); font-size: 11px; white-space: nowrap; }
.theme-toggle svg, .menu-toggle svg { width: 15px; height: 15px; }
.theme-toggle:hover, .menu-toggle:hover { color: var(--ink); border-color: var(--magic-violet); }
.layout { margin-left: var(--sidebar-width); display: grid; grid-template-columns: minmax(0, 790px) 180px; gap: 48px; padding: 48px 42px 70px; max-width: 1390px; }
main { min-width: 0; }
.eyebrow { color: var(--accent); font-size: 10px; font-weight: 750; letter-spacing: 2.3px; text-transform: uppercase; margin: 0 0 10px; }
.page-heading h1 { color: var(--ink); font-size: clamp(28px,3vw,40px); line-height: 1.2; font-weight: 700; letter-spacing: -1.5px; margin: 0 0 13px; overflow-wrap: anywhere; }
.page-heading { margin-bottom: 27px; }
.page-heading .source { font: 11px/1.5 ui-monospace,monospace; color: var(--muted); }
.package-authors { margin: -14px 0 27px; color: var(--muted); font-size: 14px; }
.markdown-body { overflow-wrap: anywhere; }
.markdown-body > :first-child { margin-top: 0; }
.markdown-body h1, .markdown-body h2, .markdown-body h3, .markdown-body h4, .markdown-body h5, .markdown-body h6 { color: var(--ink); font-weight: 650; line-height: 1.35; scroll-margin-top: 90px; }
.markdown-body h1 { font-size: 27px; letter-spacing: -.5px; margin: 38px 0 16px; }
.markdown-body h2 { font-size: 21px; letter-spacing: -.3px; margin: 32px 0 12px; }
.markdown-body h3 { font-size: 17px; margin: 27px 0 10px; }
.markdown-body p { margin: 0 0 17px; }
.markdown-body ul, .markdown-body ol { margin: 0 0 20px; padding-left: 25px; }
.markdown-body li { margin: 5px 0; padding-left: 3px; }
.markdown-body li > ul, .markdown-body li > ol { margin: 4px 0 10px; }
.markdown-body blockquote { padding: 12px 19px; margin: 22px 0; border-left: 3px solid var(--magic-violet); color: var(--muted); background: var(--soft); border-radius: 0 6px 6px 0; }
.markdown-body blockquote p:last-child { margin-bottom: 0; }
.markdown-body hr { border: 0; border-top: 1px solid var(--border); margin: 32px 0; }
.markdown-body table { display: block; max-width: 100%; overflow-x: auto; border-collapse: collapse; font-size: 13px; margin: 20px 0; }
.markdown-body th, .markdown-body td { border: 1px solid var(--border); padding: 9px 14px; text-align: left; }
.markdown-body th { background: var(--soft); color: var(--ink); font-weight: 650; }
.markdown-body img { max-width: 100%; height: auto; }
.markdown-body input[type='checkbox'] { accent-color: var(--accent); margin-right: 6px; }
code, pre { font-family: ui-monospace, SFMono-Regular, Consolas, 'Liberation Mono', monospace; }
:not(pre) > code { background: var(--soft); border: 1px solid var(--border); border-radius: 4px; font-size: .86em; padding: 2px 5px; color: var(--ink); }
code a { color: inherit; text-decoration-style: dotted; }
.code-example { overflow: hidden; margin: 22px 0 25px; border: 1px solid var(--border); border-radius: 8px; background: var(--code); }
.code-toolbar { display: flex; justify-content: space-between; align-items: center; min-height: 36px; padding: 0 16px; border-bottom: 1px solid var(--border); color: var(--muted); font: 10px/1.5 ui-sans-serif,system-ui,sans-serif; letter-spacing: .6px; }
.copy-code { padding: 5px 0 5px 10px; border: 0; background: transparent; color: var(--muted); font-size: 10px; letter-spacing: 0; }
.copy-code:hover { color: var(--accent); }
pre { padding: 18px 20px; margin: 0; overflow-x: auto; tab-size: 2; font-size: 12px; line-height: 1.85; color: var(--ink); }
pre code { white-space: pre; }
.syntax-keyword { color: var(--keyword); font-weight: 600; }
.syntax-string { color: var(--string); }
.syntax-number { color: var(--number); }
.syntax-type { color: var(--type); }
.syntax-comment { color: var(--muted); font-style: italic; }
.api-summary { margin: 34px 0 42px; padding: 19px 22px; border: 1px solid var(--border); background: var(--surface); border-radius: 8px; }
.api-summary h2 { margin: 0 0 12px; color: var(--muted); font-size: 10px; font-weight: 750; text-transform: uppercase; letter-spacing: 1.8px; }
.summary-links { list-style: none; padding: 0; margin: 0; display: grid; grid-template-columns: repeat(2,minmax(0,1fr)); gap: 6px 20px; }
.summary-links a { color: var(--ink); text-decoration: none; font: 12px/1.8 ui-monospace,monospace; }
.summary-links a:hover { color: var(--accent); }
.summary-links small { color: var(--muted); font: 10px ui-sans-serif,system-ui,sans-serif; margin-right: 7px; }
.api-entry { scroll-margin-top: 92px; padding-top: 31px; margin-top: 35px; border-top: 1px solid var(--border); }
.entry-header { display: flex; justify-content: space-between; align-items: center; gap: 12px; margin-bottom: 15px; }
.entry-title { display: flex; align-items: center; gap: 10px; min-width: 0; }
.entry-title h2, .entry-title h3 { margin: 0; color: var(--ink); font: 650 20px/1.5 ui-monospace,monospace; overflow-wrap: anywhere; }
.kind-badge { padding: 2px 7px; border: 1px solid var(--border); border-radius: 4px; color: var(--muted); font-size: 9px; text-transform: uppercase; font-weight: 650; letter-spacing: .5px; }
.permalink { font-size: 14px; text-decoration: none; color: var(--muted); opacity: .5; }
.entry-header:hover .permalink { opacity: 1; color: var(--accent); }
.source { color: var(--muted); font: 10px/1.6 ui-monospace,monospace; white-space: nowrap; }
.signature { background: var(--code); border: 1px solid var(--border); border-radius: 6px; padding: 14px 17px; margin-bottom: 12px; font-size: 12px; }
.inferred { display: flex; align-items: baseline; gap: 10px; color: var(--muted); font-size: 11px; margin: 0 0 20px; }
.inferred > span { font: 8px/1.5 ui-sans-serif,system-ui,sans-serif; font-weight: 750; letter-spacing: 1px; }
.inferred code { padding: 0; background: transparent; border: 0; font-size: 11px; }
.api-entry.member { margin-left: 15px; padding-left: 18px; border-left: 2px solid var(--border); border-top: 0; padding-top: 3px; }
.member .entry-title h3 { font-size: 16px; }
.member .entry-header { flex-wrap: wrap; }
.contents { align-self: start; position: sticky; top: 102px; max-height: calc(100vh - 132px); overflow-y: auto; scrollbar-width: thin; }
.contents h2 { margin: 2px 0 12px; color: var(--muted); font-size: 9px; text-transform: uppercase; letter-spacing: 1.8px; font-weight: 750; }
.contents ul { list-style: none; margin: 0; padding: 0; border-left: 1px solid var(--border); }
.contents a { display: block; padding: 5px 0 5px 15px; color: var(--muted); font-size: 13px; text-decoration: none; border-left: 2px solid transparent; margin-left: -1px; overflow-wrap: anywhere; }
.contents ul ul { border-left: 0; margin: 0 0 6px 12px; }
.contents ul ul a { font-size: 12px; }
.contents a:hover, .contents a[aria-current='location'] { color: var(--accent); border-color: var(--lantern-orange); }
@media(min-width:1600px) { .layout { padding-left: 64px; } .topbar { padding-left: 64px; } }
@media(max-width:1200px) { .layout { grid-template-columns: minmax(0,1fr); max-width: 1100px; padding: 40px 35px 60px; } .contents { display: none; } }
@media(min-width:801px) { .menu-toggle { display: none; } }
@media(max-width:800px) {
  :root { --sidebar-width: 290px; }
  .sidebar { position: static; width: auto; max-height: 70vh; }
  .js .sidebar { position: fixed; width: var(--sidebar-width); max-height: none; transform: translateX(-100%); transition: transform .18s; box-shadow: var(--shadow); }
  body.menu-open .sidebar { transform: translateX(0); }
  .topbar { margin-left: 0; padding: 0 18px; height: 60px; }
  .layout { margin-left: 0; padding: 29px 20px 45px; }
  .breadcrumb { font-size: 10px; gap: 6px; }
  .theme-label { display: none; }
  .entry-header { flex-wrap: wrap; }
  .entry-title h2 { font-size: 18px; }
  .summary-links { grid-template-columns: 1fr; }
  pre { font-size: 11px; padding: 14px; }
  .api-entry.member { margin-left: 4px; padding-left: 11px; }
}
@media(prefers-reduced-motion:reduce) { html { scroll-behavior: auto; } *, *::before, *::after { transition: none !important; } }
@media print { .sidebar,.topbar,.contents,.copy-code { display: none !important; } .layout { display: block; margin: 0; padding: 0; } body { background: white; color: black; } }
"

pub const javascript =
  "
(() => {
  'use strict';
  const root = document.documentElement;
  const media = window.matchMedia('(prefers-color-scheme: dark)');
  const storedTheme = () => { try { const t = localStorage.getItem('pooka-docs-theme'); return ['light', 'dark'].includes(t) ? t : null; } catch { return null; } };
  const themeButton = document.querySelector('[data-theme-toggle]');
  const applyTheme = theme => {
    root.dataset.theme = theme;
    if (themeButton) {
      const next = theme === 'dark' ? 'light' : 'dark';
      themeButton.setAttribute('aria-label', 'Switch to ' + next + ' mode');
      themeButton.setAttribute('aria-pressed', String(theme === 'dark'));
      themeButton.querySelector('.theme-label').textContent = theme === 'dark' ? 'Dark' : 'Light';
    }
  };
  applyTheme(storedTheme() || (media.matches ? 'dark' : 'light'));
  if (themeButton) {
    themeButton.hidden = false;
    themeButton.addEventListener('click', () => {
      const next = root.dataset.theme === 'dark' ? 'light' : 'dark';
      try { localStorage.setItem('pooka-docs-theme', next); } catch {  }
      applyTheme(next);
    });
  }
  media.addEventListener('change', e => { if (!storedTheme()) applyTheme(e.matches ? 'dark' : 'light'); });
  const search = document.querySelector('[data-nav-search]');
  const trees = Array.from(document.querySelectorAll('.module-tree'));
  const empty = document.querySelector('[data-search-empty]');
  if (search) search.addEventListener('input', () => {
    const query = search.value.trim().toLowerCase();
    const words = query.split(/\\s+/).filter(Boolean);
    let visible = 0;
    trees.forEach(tree => {
      const moduleMatch = words.every(w => tree.dataset.module.includes(w));
      const rows = Array.from(tree.querySelectorAll('[data-search]'));
      let found = moduleMatch;
      rows.forEach(row => {
        const matches = moduleMatch || words.every(w => row.dataset.search.includes(w));
        row.hidden = !matches;
        if (matches) found = true;
      });

      rows.slice().reverse().forEach(row => { if (!row.hidden) { const parent = row.parentElement.closest('[data-search]'); if (parent) parent.hidden = false; } });
      tree.querySelectorAll('[data-symbol-group]').forEach(group => { group.hidden = !Array.from(group.querySelectorAll('[data-search]')).some(row => !row.hidden); });
      tree.hidden = !found;
      tree.open = query ? found : tree.hasAttribute('data-current');
      if (found) visible++;
    });
    if (empty) empty.hidden = visible !== 0;
  });
  document.addEventListener('keydown', e => {
    if (e.key === '/' && !e.ctrlKey && !e.metaKey && !e.altKey && !e.target.closest('input,textarea,[contenteditable]') && search) {
      e.preventDefault(); document.body.classList.add('menu-open'); const toggle = document.querySelector('[data-menu-toggle]'); if (toggle) toggle.setAttribute('aria-expanded','true'); search.focus();
    }
    if (e.key === 'Escape') { document.body.classList.remove('menu-open'); const toggle = document.querySelector('[data-menu-toggle]'); if (toggle) toggle.setAttribute('aria-expanded','false'); if (search && document.activeElement === search) search.blur(); }
  });
  const menu = document.querySelector('[data-menu-toggle]');
  if (menu) { menu.hidden = false; menu.addEventListener('click', () => { const open = document.body.classList.toggle('menu-open'); menu.setAttribute('aria-expanded', String(open)); }); }
  document.addEventListener('click', e => {
    if (!e.target.closest('.sidebar,[data-menu-toggle]')) { document.body.classList.remove('menu-open'); if (menu) menu.setAttribute('aria-expanded','false'); }
  });
  document.querySelectorAll('[data-copy-code]').forEach(button => {
    button.hidden = false;
    button.addEventListener('click', async () => {
      const code = button.closest('.code-example').querySelector('code').textContent;
      let copied = false;
      try {
        if (navigator.clipboard && window.isSecureContext) { await navigator.clipboard.writeText(code); copied = true; }
      } catch {  }
      if (!copied) {
        const field = document.createElement('textarea'); field.value = code; field.style.cssText = 'position:fixed;left:-9999px;top:0';
        document.body.appendChild(field); field.select();
        try { copied = document.execCommand('copy'); } catch {  }
        field.remove(); button.focus();
      }
      if (copied) button.textContent = 'Copied!';
      else {
        const range = document.createRange(); range.selectNodeContents(button.closest('.code-example').querySelector('code'));
        const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range); button.textContent = 'Code selected';
      }
      setTimeout(() => { button.textContent = 'Copy code'; }, 1800);
    });
  });
  const activeLinks = document.querySelectorAll('.symbol-link,.contents a');
  const activate = id => activeLinks.forEach(link => {
    const current = new URL(link.href).pathname === window.location.pathname && new URL(link.href).hash === '#' + id;
    if (current) link.setAttribute('aria-current','location'); else link.removeAttribute('aria-current');
  });
  window.addEventListener('hashchange', () => activate(decodeURIComponent(window.location.hash.slice(1))));
  if (window.location.hash) activate(decodeURIComponent(window.location.hash.slice(1)));
  if ('IntersectionObserver' in window) {
    const observer = new IntersectionObserver(entries => { entries.filter(e => e.isIntersecting).sort((a,b) => a.boundingClientRect.top - b.boundingClientRect.top).slice(0,1).forEach(e => activate(e.target.id)); }, { rootMargin: '-80px 0px -65% 0px', threshold: 0 });
    document.querySelectorAll('.api-entry').forEach(section => observer.observe(section));
  }
})();
"
