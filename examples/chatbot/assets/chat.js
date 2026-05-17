// chat.js -- vanilla JS, ~120 lines. Wires the composer to /api/send
// and renders the resulting messages. Phase A is synchronous: send,
// wait for the full reply, render. Phase B adds SSE streaming.

(function () {
  var messagesEl = document.getElementById('messages');
  var formEl     = document.getElementById('composer');
  var inputEl    = document.getElementById('composer-input');
  var btnEl      = document.getElementById('send-btn');
  var statusEl   = document.getElementById('status');

  // Boot from the inline JSON the server embedded in the page.
  var boot;
  try {
    boot = JSON.parse(document.getElementById('bootdata').textContent);
  } catch (e) {
    boot = { messages: [] };
  }
  boot.messages.forEach(appendMessage);
  scrollToEnd();

  function appendMessage(msg) {
    var li = document.createElement('li');
    li.className = 'msg ' + msg.role;
    if (msg.role === 'assistant') {
      li.innerHTML = renderMarkdown(msg.content);
    } else {
      li.textContent = msg.content;
    }
    messagesEl.appendChild(li);
  }

  function appendError(text) {
    var li = document.createElement('li');
    li.className = 'msg error';
    li.textContent = text;
    messagesEl.appendChild(li);
  }

  function scrollToEnd() {
    messagesEl.scrollTop = messagesEl.scrollHeight;
  }

  function setSending(on) {
    btnEl.disabled = on;
    inputEl.disabled = on;
    statusEl.textContent = on ? 'Thinking…' : '';
  }

  formEl.addEventListener('submit', function (ev) {
    ev.preventDefault();
    var content = inputEl.value.trim();
    if (!content) return;

    // Optimistically render the user turn.
    appendMessage({ role: 'user', content: content });
    inputEl.value = '';
    scrollToEnd();
    setSending(true);

    var body = new URLSearchParams();
    body.set('content', content);

    fetch('/api/send', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString()
    })
      .then(function (r) { return r.json().then(function (j) { return { status: r.status, body: j }; }); })
      .then(function (out) {
        if (out.status >= 400) {
          appendError('error: ' + (out.body.error || out.status));
          return;
        }
        if (out.body.stop_reason === 'error' || out.body.stop_reason === 'no_message' || /^http_/.test(out.body.stop_reason)) {
          appendError('backend error (stop_reason=' + out.body.stop_reason + '). Check CHAT_BACKEND is reachable and CHAT_MODEL is correct.');
          return;
        }
        appendMessage({ role: 'assistant', content: out.body.content });
        scrollToEnd();
      })
      .catch(function (err) {
        appendError('network error: ' + err.message);
      })
      .finally(function () {
        setSending(false);
        inputEl.focus();
      });
  });

  // Cmd/Ctrl+Enter to send.
  inputEl.addEventListener('keydown', function (ev) {
    if ((ev.metaKey || ev.ctrlKey) && ev.key === 'Enter') {
      ev.preventDefault();
      formEl.requestSubmit();
    }
  });
})();
