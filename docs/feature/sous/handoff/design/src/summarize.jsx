// AI Summarize overlay — "the Loom".
// Drawer that slides from the right and gathers the conversation into strands.
// Each summary point cites source messages by id; clicking a citation would
// scroll back to the warp (highlighted briefly).

function SummarizeOverlay({ open, onClose, serifAI, onJumpTo }) {
  const { SUMMARY, USERS } = window.TENUN;
  const [loading, setLoading] = React.useState(false);
  const [phase, setPhase] = React.useState('ready'); // 'loading' | 'ready'

  React.useEffect(() => {
    if (open) {
      setPhase('loading');
      const t = setTimeout(() => setPhase('ready'), 1100);
      return () => clearTimeout(t);
    }
  }, [open]);

  if (!open) return null;

  return (
    <div className="sum-overlay" role="dialog" aria-label="Summary">
      <div className="sum-backdrop" onClick={onClose} />
      <div className="sum-drawer">
        <header className="sum-head">
          <div className="sum-head-l">
            <div className="sum-head-mark">
              <span className="sum-head-spark" />
            </div>
            <div>
              <h2 className={`sum-title ${serifAI ? 'is-serif' : ''}`}>
                The Loom · <em>#{SUMMARY.channel}</em>
              </h2>
              <div className="sum-range">{SUMMARY.range}</div>
            </div>
          </div>
          <div className="sum-head-r">
            <div className="sum-scope">
              <button className="sum-scope-btn is-active">Today</button>
              <button className="sum-scope-btn">7d</button>
              <button className="sum-scope-btn">30d</button>
              <button className="sum-scope-btn">Custom</button>
            </div>
            <button className="sum-close" onClick={onClose}>{I.x}</button>
          </div>
        </header>

        {phase === 'loading' ? (
          <div className="sum-loading">
            <LoomLoader size={40} />
            <div className={`sum-loading-label ${serifAI ? 'is-serif' : ''}`}>
              gathering the threads…
            </div>
            <div className="sum-loading-sub">
              reading 9 messages · 6 thread replies · 4 voices
            </div>
            <div className="sum-loading-trace">
              <span className="sum-trace-line" /> chunking
              <span className="sum-trace-line" /> embedding
              <span className="sum-trace-line" /> reducing
            </div>
          </div>
        ) : (
          <div className="sum-body">
            {/* Strand legend */}
            <div className="sum-legend">
              <span className="sum-legend-label">Voices:</span>
              {Array.from(new Set(SUMMARY.threads.flatMap((t) => t.strands))).map((u) => (
                <span key={u} className="sum-legend-pill">
                  <span className="sum-legend-sw" style={{ background: USERS[u].color }} />
                  {USERS[u].name}
                </span>
              ))}
            </div>

            {SUMMARY.threads.map((t, ti) => (
              <section key={ti} className="sum-thread">
                <div className="sum-thread-hd">
                  <div className="sum-thread-strands">
                    {t.strands.map((u, i) => (
                      <span key={u} className="sum-strand" style={{ background: USERS[u].color, '--i': i }} />
                    ))}
                  </div>
                  <h3 className={`sum-thread-title ${serifAI ? 'is-serif' : ''}`}>{t.title}</h3>
                </div>
                <ul className="sum-points">
                  {t.points.map((p, pi) => (
                    <li key={pi} className="sum-point">
                      <span className="sum-point-bullet" />
                      <div className="sum-point-text">{p.text}</div>
                      <div className="sum-point-srcs">
                        {p.src.map((s) => (
                          <button key={s} className="sum-point-src" onClick={() => onJumpTo(s)}>
                            {s} {I.jump}
                          </button>
                        ))}
                      </div>
                    </li>
                  ))}
                </ul>
              </section>
            ))}

            <section className="sum-followups">
              <h3 className={`sum-thread-title ${serifAI ? 'is-serif' : ''}`}>Followups</h3>
              <ul className="sum-followup-list">
                {SUMMARY.followups.map((f, i) => (
                  <li key={i} className="sum-followup">
                    <span className="sum-followup-check" />
                    <span>{f}</span>
                    <button className="sum-followup-act">Make task {I.chevRight}</button>
                  </li>
                ))}
              </ul>
            </section>

            <footer className="sum-foot">
              <div className="sum-foot-meta">
                <span className="sum-foot-model">claude-haiku-4-5 · 1.8s · 4.2k tokens</span>
                <span className="sum-foot-dot">·</span>
                <span>woven from 9 messages, 6 replies</span>
              </div>
              <div className="sum-foot-actions">
                <button className="sum-foot-btn">Pin to sidebar</button>
                <button className="sum-foot-btn">Copy as markdown</button>
                <button className="sum-foot-btn sum-foot-btn--primary">Post to #deploys</button>
              </div>
            </footer>
          </div>
        )}
      </div>
    </div>
  );
}

window.SummarizeOverlay = SummarizeOverlay;
