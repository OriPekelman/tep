// compare.js -- Phase E. POST prompt to /api/compare, render N
// backend responses side-by-side. Vanilla JS, ~80 lines.

(function () {
  var gridEl   = document.getElementById('compare-grid');
  var formEl   = document.getElementById('prompt-form');
  var inputEl  = document.getElementById('prompt-input');
  var btnEl    = document.getElementById('prompt-btn');
  var statusEl = document.getElementById('compare-status');

  // Initial render: empty cards keyed by (backend, model).
  var backends = [];
  try {
    backends = JSON.parse(document.getElementById('bootbackends').textContent);
  } catch (e) { backends = []; }
  renderEmptyCards(backends);

  function renderEmptyCards(list) {
    gridEl.innerHTML = '';
    list.forEach(function (b, i) {
      var card = document.createElement('article');
      card.className = 'compare-card';
      card.dataset.index = i;
      card.innerHTML =
        '<header class="card-head">' +
          '<strong>' + escapeHtml(b.model) + '</strong>' +
          '<span class="card-backend">' + escapeHtml(b.backend) + '</span>' +
        '</header>' +
        '<div class="card-meta"><span class="card-time"></span></div>' +
        '<div class="card-body"><em>Waiting…</em></div>';
      gridEl.appendChild(card);
    });
  }

  function renderResults(out) {
    statusEl.textContent =
      'fan-out done in ' + (out.total_ms / 1000).toFixed(1) + 's';
    var cards = gridEl.querySelectorAll('.compare-card');
    out.results.forEach(function (r, i) {
      var card = cards[i];
      if (!card) return;
      card.querySelector('.card-time').textContent = r.took_s + 's';
      var body = card.querySelector('.card-body');
      if (r.content.length === 0) {
        body.innerHTML = '<em class="card-empty">(empty reply — backend unreachable?)</em>';
      } else {
        body.innerHTML = renderMarkdown(r.content);
      }
    });
  }

  function setSending(on) {
    btnEl.disabled = on;
    inputEl.disabled = on;
    statusEl.textContent = on ? 'fan-out running…' : '';
  }

  formEl.addEventListener('submit', function (ev) {
    ev.preventDefault();
    var prompt = inputEl.value.trim();
    if (!prompt) return;
    setSending(true);
    renderEmptyCards(backends);  // reset to "Waiting…"

    var body = new URLSearchParams();
    body.set('prompt', prompt);
    fetch('/api/compare', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString()
    })
      .then(function (r) { return r.json(); })
      .then(renderResults)
      .catch(function (err) {
        statusEl.textContent = 'error: ' + err.message;
      })
      .finally(function () { setSending(false); });
  });

  // Cmd/Ctrl+Enter to send.
  inputEl.addEventListener('keydown', function (ev) {
    if ((ev.metaKey || ev.ctrlKey) && ev.key === 'Enter') {
      ev.preventDefault();
      formEl.requestSubmit();
    }
  });

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
})();
