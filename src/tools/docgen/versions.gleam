//// HexDocs keeps the shelves; this switch chooses a published edition.
////
//// The host supplies docs_config.js and its versionNodes list. Load that list
//// only on the package's own HexDocs origin, then enhance the plain version
//// badge with a native select. Offline/local pages need no network access.
////
//// ```text
//// /0.1.0/module-list.html -> /docs_config.js -> choose /0.2.0
//// ```

// SPDX-License-Identifier: Apache-2.0

pub const javascript =
  "
// HexDocs supplies versionNodes. Read it only on this package's hosted origin;
// a file:// preview keeps its ordinary version badge and makes no requests.
(() => {
  const control = document.querySelector('[data-doc-version]');
  if (!control) return;
  const current = control.querySelector('[data-version-current]');
  const select = control.querySelector('[data-version-select]');
  if (!current || !select) return;
  let origin;
  try {
    origin = new URL(control.dataset.docsUrl).origin;
    if (window.location.protocol !== 'https:' || window.location.origin !== origin) return;
  } catch { return; }

  const install = () => {
    if (!Array.isArray(window.versionNodes)) return;
    const entries = [];
    const seen = new Set();
    const versionPattern = /^v?[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\\+[0-9A-Za-z.-]+)?$/;
    for (const node of window.versionNodes) {
      if (!node || typeof node.version !== 'string' || typeof node.url !== 'string' || !versionPattern.test(node.version)) continue;
      const version = node.version.replace(/^v/, '');
      if (seen.has(version)) continue;
      try {
        const url = new URL(node.url, origin);
        if (url.protocol !== 'https:' || url.origin !== origin || url.username || url.password || url.search || url.hash) continue;
        if (decodeURIComponent(url.pathname).replace(/\\/$/, '') !== '/' + version) continue;
        seen.add(version);
        entries.push({ version, url: url.href, latest: node.latest === true });
      } catch { /* Leave malformed registry entries out of the menu. */ }
    }
    if (!entries.length) return;
    const active = control.dataset.version;
    select.replaceChildren();
    // Older docs can discover future releases without being regenerated. Keep
    // the current version visible even while HexDocs is indexing its upload.
    if (!entries.some(entry => entry.version === active)) {
      const option = document.createElement('option');
      option.textContent = 'v' + active;
      option.value = window.location.href;
      option.selected = true;
      option.disabled = true;
      select.appendChild(option);
    }
    const destinations = new Set();
    for (const entry of entries) {
      const option = document.createElement('option');
      option.textContent = 'v' + entry.version + (entry.latest ? ' (latest)' : '');
      option.value = entry.url;
      option.selected = entry.version === active;
      option.disabled = entry.version === active;
      destinations.add(entry.url);
      select.appendChild(option);
    }
    select.addEventListener('change', () => {
      if (destinations.has(select.value)) window.location.assign(select.value);
    });
    current.hidden = true;
    select.hidden = false;
  };

  if (Array.isArray(window.versionNodes)) install();
  else {
    const script = document.createElement('script');
    script.src = new URL('/docs_config.js', origin).href;
    script.async = true;
    script.onload = install;
    script.onerror = () => { /* The current version badge remains usable. */ };
    document.head.appendChild(script);
  }
})();
"
