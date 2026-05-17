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

    // Pre-create the assistant message so we can append deltas
    // into it as they arrive. Phase B streams via SSE; Phase A's
    // /api/send (non-streaming JSON) stays as a fallback.
    var assistantLi = document.createElement('li');
    assistantLi.className = 'msg assistant';
    var rawContent = '';
    messagesEl.appendChild(assistantLi);

    var body = new URLSearchParams();
    body.set('content', content);

    fetch('/api/stream', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString()
    })
      .then(function (resp) {
        if (!resp.ok) {
          appendError('error: HTTP ' + resp.status);
          return null;
        }
        var reader = resp.body.getReader();
        var decoder = new TextDecoder();
        var buf = '';
        return readChunk(reader, decoder, buf, assistantLi, function (acc) { rawContent = acc; });
      })
      .catch(function (err) {
        appendError('network error: ' + err.message);
      })
      .finally(function () {
        setSending(false);
        inputEl.focus();
      });
  });

  // Pull the next chunk off the reader, split out complete SSE
  // events on \n\n, parse each `data: {"content":"<delta>"}` and
  // append into the assistant <li>. Re-render markdown after every
  // batch so code blocks etc. stay structured even mid-stream.
  function readChunk(reader, decoder, buf, liEl, setAcc) {
    return reader.read().then(function (out) {
      if (out.done) return;
      buf += decoder.decode(out.value, { stream: true });
      var sep;
      while ((sep = buf.indexOf('\n\n')) >= 0) {
        var ev = buf.slice(0, sep);
        buf = buf.slice(sep + 2);
        if (!ev.startsWith('data: ')) continue;
        var data = ev.slice(6);
        if (data === '[DONE]') {
          buf = '';
          continue;
        }
        try {
          var obj = JSON.parse(data);
          if (obj.content) {
            liEl.dataset.raw = (liEl.dataset.raw || '') + obj.content;
            liEl.innerHTML = renderMarkdown(liEl.dataset.raw);
            scrollToEnd();
          }
        } catch (e) {
          // Malformed SSE frame; ignore and keep reading.
        }
      }
      return readChunk(reader, decoder, buf, liEl, setAcc);
    });
  }

  // Cmd/Ctrl+Enter to send.
  inputEl.addEventListener('keydown', function (ev) {
    if ((ev.metaKey || ev.ctrlKey) && ev.key === 'Enter') {
      ev.preventDefault();
      formEl.requestSubmit();
    }
  });
})();
