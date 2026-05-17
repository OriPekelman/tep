// markdown.js -- ~60 lines, vanilla. Subset chosen to match what
// LLM assistants actually emit; not a full CommonMark implementation.
//
// Supported:
//   - Fenced code blocks: ```lang\n...\n```
//   - Inline code: `code`
//   - Bold: **text**
//   - Italic: *text*
//   - Links: [label](url)
//   - Paragraph breaks: double newline
//   - Newlines preserved inside paragraphs
//
// Not supported (escape-and-pass-through):
//   - Headings, lists, blockquotes, tables, images, HTML

(function (global) {
  function escapeHtml(s) {
    return s
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function renderInline(s) {
    // Inline code first (so its contents are not further processed).
    var parts = [];
    var i = 0;
    while (i < s.length) {
      var tick = s.indexOf('`', i);
      if (tick < 0) { parts.push(['text', s.slice(i)]); break; }
      var close = s.indexOf('`', tick + 1);
      if (close < 0) { parts.push(['text', s.slice(i)]); break; }
      if (tick > i) parts.push(['text', s.slice(i, tick)]);
      parts.push(['code', s.slice(tick + 1, close)]);
      i = close + 1;
    }
    return parts.map(function (p) {
      if (p[0] === 'code') return '<code>' + escapeHtml(p[1]) + '</code>';
      var t = escapeHtml(p[1]);
      // Links [label](url)
      t = t.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g,
        function (_, lbl, url) { return '<a href="' + url + '" rel="noopener">' + lbl + '</a>'; });
      // Bold **text** (before italic so doubled asterisks bind tighter)
      t = t.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
      // Italic *text*
      t = t.replace(/\*([^*]+)\*/g, '<em>$1</em>');
      return t;
    }).join('');
  }

  function renderMarkdown(src) {
    // Split off fenced code blocks first; they're not subject to
    // inline processing.
    var out = [];
    var rest = src;
    while (true) {
      var open = rest.indexOf('```');
      if (open < 0) { out.push(['md', rest]); break; }
      if (open > 0) out.push(['md', rest.slice(0, open)]);
      var afterOpen = open + 3;
      var nlAfterOpen = rest.indexOf('\n', afterOpen);
      if (nlAfterOpen < 0) { out.push(['md', rest.slice(open)]); break; }
      var close = rest.indexOf('```', nlAfterOpen + 1);
      if (close < 0) { out.push(['md', rest.slice(open)]); break; }
      out.push(['code', rest.slice(nlAfterOpen + 1, close)]);
      rest = rest.slice(close + 3);
    }
    return out.map(function (chunk) {
      if (chunk[0] === 'code') {
        return '<pre><code>' + escapeHtml(chunk[1]) + '</code></pre>';
      }
      // Split on double-newline paragraphs.
      var paragraphs = chunk[1].split(/\n{2,}/);
      return paragraphs
        .filter(function (p) { return p.length > 0; })
        .map(function (p) { return '<p>' + renderInline(p) + '</p>'; })
        .join('');
    }).join('');
  }

  global.renderMarkdown = renderMarkdown;
})(window);
