// Lightweight inline-markdown renderer + a markdown demo block.
// Supports: **bold**, *italic*, `code`, [text](url), and converts in-text only.
// Block-level (paragraph, code block, list, blockquote, heading) is handled
// elsewhere via the explicit body item types in data.js.

function renderInline(text) {
  // Tokenise into [bold, italic, code, link, customer, plain] preserving order.
  const tokens = [];
  const re = /\*\*([^*]+)\*\*|\*([^*]+)\*|`([^`]+)`|\[([^\]]+)\]\(([^)]+)\)|&(\w+)/g;
  let last = 0, m;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) tokens.push({ k: 'plain', v: text.slice(last, m.index) });
    if (m[1] != null)       tokens.push({ k: 'b', v: m[1] });
    else if (m[2] != null)  tokens.push({ k: 'i', v: m[2] });
    else if (m[3] != null)  tokens.push({ k: 'code', v: m[3] });
    else if (m[4] != null)  tokens.push({ k: 'a', v: m[4], href: m[5] });
    else if (m[6] != null)  tokens.push({ k: 'cust', v: m[6] });
    last = re.lastIndex;
  }
  if (last < text.length) tokens.push({ k: 'plain', v: text.slice(last) });
  return tokens.map((t, i) => {
    if (t.k === 'b')    return <strong key={i}>{t.v}</strong>;
    if (t.k === 'i')    return <em key={i}>{t.v}</em>;
    if (t.k === 'code') return <code key={i} className="md-code">{t.v}</code>;
    if (t.k === 'a')    return <a key={i} href={t.href} className="md-link">{t.v}</a>;
    if (t.k === 'cust') {
      const c = window.TENUN.CUSTOMERS[t.v];
      return <span key={i} className="md-customer">&amp;{c ? c.name : t.v}</span>;
    }
    return <span key={i}>{t.v}</span>;
  });
}

// A full Markdown reference card — used in #deploys when Mina shares it for review.
function MarkdownDemo() {
  return (
    <div className="md-demo">
      <div className="md-demo-head">
        <span className="md-demo-tag">Markdown reference · v0.2</span>
        <span className="md-demo-meta">draft · for help docs</span>
      </div>
      <div className="md-demo-body">
        <div className="md-demo-row">
          <div className="md-demo-src">{`**bold** · *italic* · ~~strike~~ · \`code\``}</div>
          <div className="md-demo-out">
            <strong>bold</strong> · <em>italic</em> · <s>strike</s> · <code className="md-code">code</code>
          </div>
        </div>
        <div className="md-demo-row">
          <div className="md-demo-src">{`# heading 1\n## heading 2`}</div>
          <div className="md-demo-out">
            <div className="md-h1">heading 1</div>
            <div className="md-h2">heading 2</div>
          </div>
        </div>
        <div className="md-demo-row">
          <div className="md-demo-src">{`> woven, considered\n> — m. lin`}</div>
          <div className="md-demo-out">
            <blockquote className="md-quote">
              woven, considered<br />— m. lin
            </blockquote>
          </div>
        </div>
        <div className="md-demo-row">
          <div className="md-demo-src">{`- warp\n- weft\n- selvedge`}</div>
          <div className="md-demo-out">
            <ul className="md-list">
              <li>warp</li>
              <li>weft</li>
              <li>selvedge</li>
            </ul>
          </div>
        </div>
        <div className="md-demo-row">
          <div className="md-demo-src">{`[Tenun](https://tenun.app)`}</div>
          <div className="md-demo-out">
            <a href="#" className="md-link">Tenun</a>
          </div>
        </div>
        <div className="md-demo-row md-demo-row--full">
          <div className="md-demo-src">{`\`\`\`elixir\nMessages.search("loom")\n\`\`\``}</div>
          <div className="md-demo-out">
            <pre className="md-pre"><code>{`Messages.search("loom")`}</code></pre>
          </div>
        </div>
      </div>
    </div>
  );
}

// Mini deploy metrics block.
function MetricsBlock() {
  return (
    <div className="metrics">
      <div className="metrics-hd">
        <span className="metrics-tag">staging · v2.41</span>
        <span className="metrics-live"><span className="metrics-dot" /> live</span>
      </div>
      <div className="metrics-grid">
        <div className="metrics-cell">
          <div className="metrics-label">p99 search</div>
          <div className="metrics-val">142<span>ms</span></div>
          <div className="metrics-spark">
            <svg viewBox="0 0 60 18" width="60" height="18" preserveAspectRatio="none">
              <polyline fill="none" stroke="currentColor" strokeWidth="1.4"
                points="0,12 8,10 14,14 22,8 30,11 38,7 46,9 54,5 60,7" />
            </svg>
          </div>
        </div>
        <div className="metrics-cell">
          <div className="metrics-label">error rate</div>
          <div className="metrics-val">0.02<span>%</span></div>
          <div className="metrics-spark">
            <svg viewBox="0 0 60 18" width="60" height="18" preserveAspectRatio="none">
              <polyline fill="none" stroke="currentColor" strokeWidth="1.4"
                points="0,9 8,8 14,10 22,9 30,9 38,8 46,9 54,8 60,8" />
            </svg>
          </div>
        </div>
        <div className="metrics-cell">
          <div className="metrics-label">qps</div>
          <div className="metrics-val">3.4<span>k</span></div>
          <div className="metrics-spark">
            <svg viewBox="0 0 60 18" width="60" height="18" preserveAspectRatio="none">
              <polyline fill="none" stroke="currentColor" strokeWidth="1.4"
                points="0,14 8,12 14,10 22,11 30,9 38,8 46,7 54,5 60,4" />
            </svg>
          </div>
        </div>
      </div>
    </div>
  );
}

window.renderInline = renderInline;
window.MarkdownDemo = MarkdownDemo;
window.MetricsBlock = MetricsBlock;
