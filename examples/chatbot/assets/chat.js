// chat.js -- Phase C: sidebar + multi-conversation + SSE streaming.
// Vanilla JS, ~200 lines. Polls /api/conversations every 10s to
// pick up titles set by TitleJob (background worker, server-side).

(function () {
  var chatEl     = document.getElementById('chat');
  var messagesEl = document.getElementById('messages');
  var formEl     = document.getElementById('composer');
  var inputEl    = document.getElementById('composer-input');
  var btnEl      = document.getElementById('send-btn');
  var statusEl   = document.getElementById('status');
  var convListEl = document.getElementById('conv-list');
  var newBtnEl   = document.getElementById('new-conv-btn');

  var currentConvId = parseInt(chatEl.dataset.convId || '0', 10);

  // Boot from inline JSON the server embedded.
  var bootMsgs, bootConvs;
  try { bootMsgs = JSON.parse(document.getElementById('bootmsgs').textContent); }
  catch (e) { bootMsgs = { messages: [] }; }
  try { bootConvs = JSON.parse(document.getElementById('bootconvs').textContent); }
  catch (e) { bootConvs = { conversations: [] }; }

  bootMsgs.messages.forEach(appendMessage);
  renderConvList(bootConvs.conversations);
  scrollToEnd();

  // ---------------- conversation sidebar ----------------

  function renderConvList(convs) {
    convListEl.innerHTML = '';
    convs.forEach(function (c) {
      var li = document.createElement('li');
      var label = (c.title && c.title.length > 0) ? c.title : 'New chat';
      li.textContent = label;
      if (!c.title || c.title.length === 0) li.classList.add('untitled');
      if (c.id === currentConvId) li.classList.add('active');
      li.addEventListener('click', function () {
        if (c.id !== currentConvId) {
          window.location.href = '/c/' + c.id;
        }
      });
      convListEl.appendChild(li);
    });
  }

  function refreshConvList() {
    fetch('/api/conversations')
      .then(function (r) { return r.json(); })
      .then(function (j) { renderConvList(j.conversations); })
      .catch(function () { /* ignore transient errors */ });
  }

  newBtnEl.addEventListener('click', function () {
    fetch('/api/conversations', { method: 'POST' })
      .then(function (r) { return r.json(); })
      .then(function (j) { window.location.href = '/c/' + j.id; })
      .catch(function (err) { appendError('could not create: ' + err.message); });
  });

  // Sidebar refresh tick. TitleJob latency is ~5s (poll) + ~LLM
  // round-trip; 10s is plenty.
  setInterval(refreshConvList, 10000);

  // ---------------- messages + streaming ----------------

  function appendMessage(msg) {
    var li = document.createElement('li');
    li.className = 'msg ' + msg.role;
    if (msg.role === 'assistant') {
      li.dataset.raw = msg.content;
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

    appendMessage({ role: 'user', content: content });
    inputEl.value = '';
    scrollToEnd();
    setSending(true);

    var assistantLi = document.createElement('li');
    assistantLi.className = 'msg assistant';
    assistantLi.dataset.raw = '';
    messagesEl.appendChild(assistantLi);

    var body = new URLSearchParams();
    body.set('content', content);

    fetch('/api/c/' + currentConvId + '/stream', {
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
        return readChunk(reader, decoder, '', assistantLi);
      })
      .catch(function (err) {
        appendError('network error: ' + err.message);
      })
      .finally(function () {
        setSending(false);
        inputEl.focus();
        // First reply may have triggered TitleJob -- refresh
        // sidebar sooner than the 10s tick.
        setTimeout(refreshConvList, 6000);
      });
  });

  function readChunk(reader, decoder, buf, liEl) {
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
          // ignore malformed
        }
      }
      return readChunk(reader, decoder, buf, liEl);
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
