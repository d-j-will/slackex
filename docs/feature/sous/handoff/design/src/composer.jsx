// Composer + Thread rail + AI Summarize overlay.

function Composer({ channel, dense, serifAI }) {
  const [draft, setDraft] = React.useState('');
  const [showFmt, setShowFmt] = React.useState(true);
  const [aiHint, setAiHint] = React.useState(false);
  const [echo, setEcho] = React.useState(true);

  return (
    <div className={`composer ${dense ? 'composer--dense' : ''}`}>
      {/* Echo dedup — semantic 'this was asked before' suggestion */}
      {echo && <EchoHint onDismiss={() => setEcho(false)} serifAI={serifAI} />}

      {/* Suggestion strip — semantic search teaser */}
      {aiHint && (
        <div className="composer-ai">
          <span className="composer-ai-spark" />
          <span className={serifAI ? 'composer-ai-label is-serif' : 'composer-ai-label'}>
            related from <strong>this channel</strong>:
          </span>
          <button className="composer-ai-chip">jules · chunked summariser PR (#1842) — 1h ago</button>
          <button className="composer-ai-chip">mina · pgvector backfill complete — 2h ago</button>
          <button className="composer-ai-dismiss" onClick={() => setAiHint(false)}>{I.x}</button>
        </div>
      )}

      <div className="composer-box">
        <div className="composer-toolbar">
          <button className="cmp-tool"><span title="Bold">{I.bold}</span></button>
          <button className="cmp-tool"><span title="Italic">{I.italic}</span></button>
          <button className="cmp-tool"><span title="Strike">⌐</span></button>
          <span className="cmp-divider" />
          <button className="cmp-tool"><span title="Link">{I.link}</span></button>
          <button className="cmp-tool"><span title="List">{I.list}</span></button>
          <button className="cmp-tool"><span title="Quote">{I.quote}</span></button>
          <button className="cmp-tool"><span title="Code">{I.code}</span></button>
          <span className="cmp-divider" />
          <button className="cmp-tool cmp-tool--ai" onClick={() => setAiHint(true)}>
            <span className="cmp-spark" /> <span className="cmp-tool-label">/assist</span>
          </button>
          <div className="cmp-spacer" />
          <span className="cmp-hint">⌘↵ to send</span>
        </div>

        <textarea
          className="composer-input"
          placeholder={`Message #${channel.name}`}
          rows={3}
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
        />

        <div className="composer-foot">
          <div className="composer-foot-l">
            <button className="cmp-tool"><span title="Attach">{I.attach}</span></button>
            <button className="cmp-tool"><span title="@mention">{I.at}</span></button>
            <button className="cmp-tool"><span title="Slash command">{I.slash}</span></button>
            <button className="cmp-tool"><span title="Emoji">{I.smile}</span></button>
            <button className="cmp-tool"><span title="Mic">{I.mic}</span></button>
          </div>
          <div className="composer-foot-r">
            <span className="composer-typing">
              <span className="composer-typing-dots"><i /><i /><i /></span>
              <span>mina is weaving…</span>
            </span>
            <button className="cmp-send">
              <span>Send</span>
              {I.send}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

function Thread({ rootId, onClose, serifAI }) {
  const { MESSAGES, THREAD_MESSAGES, USERS } = window.TENUN;
  const root = MESSAGES.find((m) => m.id === rootId);
  if (!root) return null;

  return (
    <aside className="thread-rail">
      <header className="thread-head">
        <div className="thread-head-l">
          <span className="thread-head-title">Thread</span>
          <span className="thread-head-sub">#deploys</span>
        </div>
        <button className="thread-close" onClick={onClose}>{I.x}</button>
      </header>

      {/* root */}
      <div className="thread-root">
        <MessageRow msg={root} serifAI={serifAI} onOpenThread={() => {}} />
        <div className="thread-divider">
          <span className="thread-divider-line" />
          <span className="thread-divider-label">{THREAD_MESSAGES.length} replies · woven</span>
          <span className="thread-divider-line" />
        </div>
      </div>

      {/* weft visualisation — replies as horizontal strands */}
      <div className="thread-weft">
        <svg viewBox="0 0 200 20" preserveAspectRatio="none" width="100%" height="20">
          {THREAD_MESSAGES.map((r, i) => (
            <line key={i} x1="0" x2="200" y1={(i + 0.5) * (20 / THREAD_MESSAGES.length)}
                  y2={(i + 0.5) * (20 / THREAD_MESSAGES.length)}
                  stroke={USERS[r.user].color} strokeWidth="1.3" strokeDasharray="2 4" opacity="0.7" />
          ))}
        </svg>
      </div>

      <div className="thread-list">
        {THREAD_MESSAGES.map((m, i) => (
          <MessageRow key={m.id} msg={m} prev={THREAD_MESSAGES[i - 1]} serifAI={serifAI} onOpenThread={() => {}} />
        ))}
      </div>

      <div className="thread-composer">
        <textarea className="composer-input" placeholder="Reply…" rows={2} />
        <div className="thread-composer-foot">
          <label className="thread-also">
            <input type="checkbox" /> Also send to #deploys
          </label>
          <button className="cmp-send cmp-send--sm">
            Reply {I.send}
          </button>
        </div>
      </div>
    </aside>
  );
}

window.Composer = Composer;
window.Thread = Thread;
