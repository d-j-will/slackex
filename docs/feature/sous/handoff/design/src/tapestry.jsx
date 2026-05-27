// The Tapestry — leadership drop-in across the whole organisation.
// A curated read of everything that matters, woven from the work,
// filtered by who you are (CEO / CTO / EM).

function Tapestry({ open, onClose, viewerId, setViewer, serifAI }) {
  const { TAPESTRY, VIEWERS, USERS } = window.TENUN;
  const viewer = VIEWERS[viewerId];
  const [phase, setPhase] = React.useState('ready');

  React.useEffect(() => {
    if (open) {
      setPhase('loading');
      const t = setTimeout(() => setPhase('ready'), 850);
      return () => clearTimeout(t);
    }
  }, [open, viewerId]);

  if (!open) return null;

  const isReduction = viewer.surface === 'reduction';
  const isStack = viewer.surface === 'stack';
  const isExpo = viewer.surface === 'expo';
  const isFloor = viewer.surface === 'floor';
  const surfaceName = isReduction ? 'the Reduction'
    : isStack ? 'the Stack'
    : isExpo ? 'the Expo'
    : isFloor ? 'the Floor'
    : 'the Pass';

  return (
    <div className={`tap-overlay ${isReduction ? 'is-reduction' : ''} ${isStack ? 'is-stack' : ''} ${isExpo ? 'is-expo' : ''} ${isFloor ? 'is-floor' : ''}`} role="dialog" aria-label={surfaceName}>
      <div className="tap-backdrop" onClick={onClose} />
      <div className="tap-shell">
        {/* Top bar */}
        <header className="tap-bar">
          <div className="tap-bar-l">
            <button className="tap-back" onClick={onClose} title="Back to channel">{I.chevLeft}</button>
            <div className="tap-bar-brand">
              <TenunMark size={18} />
              <span className="tap-bar-brand-name">Sous</span>
              <span className="tap-bar-brand-slash">/</span>
              <span className={`tap-bar-brand-here ${serifAI ? 'is-serif' : ''}`}>{surfaceName}</span>
            </div>
          </div>
          <div className="tap-bar-r">
            <div className="tap-viewer">
              <span className="tap-viewer-k">Reading as</span>
              <div className="tap-viewer-tabs">
                {Object.values(VIEWERS).map((v) => (
                  <button key={v.id}
                          className={`tap-viewer-tab ${v.id === viewerId ? 'is-active' : ''}`}
                          onClick={() => setViewer(v.id)}>
                    <span className="tap-viewer-av" style={{ background: v.color }}>{v.initial}</span>
                    <span className="tap-viewer-role">{v.role}</span>
                    <span className="tap-viewer-name">{v.name}</span>
                  </button>
                ))}
              </div>
            </div>
            <button className="tap-bar-close" onClick={onClose}>{I.x}</button>
          </div>
        </header>

        {phase === 'loading' ? (
          <div className="tap-loading">
            <LoomLoader size={48} />
            <div className={`tap-loading-label ${serifAI ? 'is-serif' : ''}`}>
              {isReduction ? `opening efdp\u2019s workbench…`
                : isStack ? `polling 41 sources for keem…`
                : isExpo ? `pulling customer voice for dave…`
                : isFloor ? `reading the room for mina…`
                : `setting the pass for ${viewer.name}…`}
            </div>
            <div className="tap-loading-sub">
              {isReduction
                ? 'reading 14 inputs across 3 threads'
                : isStack
                  ? 'cross-referencing 12 dependencies × 7 releases'
                  : isExpo
                    ? '11 voices · 7 themes · 4 orders in flight'
                    : isFloor
                      ? '3 accounts · 4 moments · 4 calls this week'
                      : `reading across 7 channels · ${window.TENUN.TAPESTRY.cadence.shipped} ships · 4d 6h`}
            </div>
          </div>
        ) : (
          <div className="tap-scroll">
            {isReduction
              ? <Reduction serifAI={serifAI} onClose={onClose} />
              : isStack
                ? <StackView serifAI={serifAI} onClose={onClose} />
                : isExpo
                  ? <Expo serifAI={serifAI} onClose={onClose} />
                  : isFloor
                    ? <Floor serifAI={serifAI} onClose={onClose} />
                    : <TapestryBody viewer={viewer} serifAI={serifAI} onClose={onClose} />}
          </div>
        )}

        {!isReduction && phase === 'ready' && null}
      </div>
    </div>
  );
}

function TapestryBody({ viewer, serifAI, onClose }) {
  const { TAPESTRY, USERS } = window.TENUN;
  const t = TAPESTRY;

  return (
    <div className="tap">
      {/* Masthead */}
      <section className="tap-mast">
        <div className="tap-mast-l">
          <div className="tap-mast-eyebrow">
            <span className="tap-mast-spark" />
            <span>Since you last looked · {t.since}</span>
          </div>
          <h1 className={`tap-mast-title ${serifAI ? 'is-serif' : ''}`}>
            Good morning, <em>{viewer.name.split(' ')[0]}</em>. <br/>
            Walking the pass.
          </h1>
        </div>
        <div className="tap-mast-r">
          <Cadence c={t.cadence} />
        </div>
      </section>

      {/* Marquee */}
      <section className="tap-marquee">
        <div className="tap-marquee-tag">
          <span className="tap-marquee-tag-dot" />
          The thing that mattered
        </div>
        <h2 className={`tap-marquee-title ${serifAI ? 'is-serif' : ''}`}>
          {t.marquee.title}
        </h2>
        <p className="tap-marquee-body">{t.marquee.body}</p>
        <div className="tap-marquee-foot">
          <span className="tap-marquee-owner">
            <span className="tap-av" style={{ background: USERS[t.marquee.owner].color }}>{USERS[t.marquee.owner].initial}</span>
            owned by {USERS[t.marquee.owner].name}
          </span>
          <div className="tap-marquee-impacts">
            {t.marquee.impact.map((s, i) => (
              <span key={i} className="tap-marquee-impact">{s}</span>
            ))}
          </div>
        </div>
      </section>

      {/* Two-column body */}
      <div className="tap-grid">
        {/* CUSTOMERS */}
        <Section title="Customers" hint={`${t.customers.healthMove.healthier} healthier · ${t.customers.healthMove.atRisk} at risk · ${t.customers.healthMove.churn} churn`} serifAI={serifAI} priority={viewer.focus.indexOf('customers')}>
          <div className="tap-customers">
            {t.customers.expansion.map((c, i) => (
              <div key={i} className="tap-cust tap-cust--expand">
                <div className="tap-cust-hd">
                  <span className="tap-cust-name">{c.name}</span>
                  <span className="tap-cust-tag tap-cust-tag--expand">expansion · {c.delta}</span>
                </div>
                <div className="tap-cust-arr">{c.arr} ARR</div>
                <div className="tap-cust-signal">{c.signal}</div>
              </div>
            ))}
            {t.customers.atRisk.map((c, i) => (
              <div key={i} className="tap-cust tap-cust--risk">
                <div className="tap-cust-hd">
                  <span className="tap-cust-name">{c.name}</span>
                  <span className="tap-cust-tag tap-cust-tag--risk">at risk</span>
                </div>
                <div className="tap-cust-arr">{c.arr} ARR · CSM {c.csm}</div>
                <div className="tap-cust-signal">{c.signal}</div>
              </div>
            ))}
          </div>
          <blockquote className={`tap-quote ${serifAI ? 'is-serif' : ''}`}>
            <div className="tap-quote-mark">"</div>
            <p>{t.customers.quote.text}</p>
            <footer>— {t.customers.quote.who} · <span>{t.customers.quote.via}</span></footer>
          </blockquote>
        </Section>

        {/* WINS */}
        <Section title="What we shipped" hint={`${t.wins.length} of note · ${t.cadence.prsMerged} merges total`} serifAI={serifAI}>
          <ul className="tap-wins">
            {t.wins.map((w, i) => (
              <li key={i} className="tap-win">
                <span className="tap-win-bullet" />
                <div className="tap-win-body">
                  <div className="tap-win-title">{w.title}</div>
                  <div className="tap-win-meta">
                    <span className="tap-av tap-av--sm" style={{ background: USERS[w.owner].color }}>{USERS[w.owner].initial}</span>
                    <span>{USERS[w.owner].name}</span>
                    <span className="tap-win-dot">·</span>
                    <span className="tap-win-meta-text">{w.meta}</span>
                  </div>
                </div>
              </li>
            ))}
          </ul>
        </Section>

        {/* DECISIONS */}
        <Section title="Decisions" hint={`${t.decisions.made.length} made · ${t.decisions.pendingYou.length} need you`} serifAI={serifAI} className="tap-section--wide">
          <div className="tap-decisions">
            <div className="tap-dec-col">
              <div className="tap-dec-col-k">Made this week</div>
              <ul className="tap-dec-list">
                {t.decisions.made.map((d, i) => {
                  const u = USERS[d.dri];
                  return (
                    <li key={i} className="tap-dec">
                      <span className="tap-dec-strand" />
                      <div className="tap-dec-body">
                        <div className="tap-dec-title">{d.title}</div>
                        <div className="tap-dec-meta">
                          <span className="tap-av tap-av--sm" style={{ background: u.color }}>{u.initial}</span>
                          <span>{u.name}</span>
                          <span className="tap-win-dot">·</span>
                          <span>{d.date}</span>
                          <span className={`tap-dec-tag tap-dec-tag--${d.tag}`}>{d.tag}</span>
                        </div>
                      </div>
                    </li>
                  );
                })}
              </ul>
            </div>
            <div className="tap-dec-col tap-dec-col--pending">
              <div className="tap-dec-col-k">Need your nod</div>
              <ul className="tap-dec-list">
                {t.decisions.pendingYou.map((d, i) => {
                  const u = USERS[d.from];
                  return (
                    <li key={i} className="tap-dec tap-dec--pending">
                      <span className="tap-dec-strand tap-dec-strand--copper" />
                      <div className="tap-dec-body">
                        <div className="tap-dec-title">{d.title}</div>
                        <div className="tap-dec-meta">
                          <span className="tap-av tap-av--sm" style={{ background: u.color }}>{u.initial}</span>
                          <span>from {u.name}</span>
                          <span className="tap-win-dot">·</span>
                          <span>{d.need}</span>
                          <span className="tap-dec-age">{d.age}</span>
                        </div>
                      </div>
                      <button className="tap-dec-act">Open {I.chevRight}</button>
                    </li>
                  );
                })}
              </ul>
            </div>
          </div>
        </Section>

        {/* PULSE */}
        <Section title="Team pulse" hint="reading mood across the team" serifAI={serifAI}>
          <ul className="tap-pulse">
            {t.pulse.teams.map((team, i) => (
              <li key={i} className="tap-team">
                <div className="tap-team-hd">
                  <span className="tap-team-name">{team.name}</span>
                  <span className="tap-team-people">
                    {team.people.map((p) => (
                      <span key={p} className="tap-av tap-av--sm" style={{ background: USERS[p].color }}>{USERS[p].initial}</span>
                    ))}
                  </span>
                </div>
                <div className="tap-team-row">
                  <span className="tap-team-stat"><b>{team.shipping}</b> shipping</span>
                  <span className="tap-team-stat tap-team-stat--block">
                    <b>{team.blocked}</b> blocked
                  </span>
                </div>
                <div className="tap-team-note">{team.note}</div>
              </li>
            ))}
          </ul>
          <div className="tap-voices">
            <div className="tap-voices-k">Mood signals</div>
            {t.pulse.voices.map((v) => (
              <div key={v.user} className={`tap-voice tap-voice--${v.tone}`}>
                <span className="tap-av tap-av--sm" style={{ background: USERS[v.user].color }}>{USERS[v.user].initial}</span>
                <span className="tap-voice-name">{USERS[v.user].name}</span>
                <span className="tap-voice-note">{v.note}</span>
              </div>
            ))}
          </div>
        </Section>

        {/* RISKS */}
        <Section title="Risks" hint="three to know" serifAI={serifAI}>
          <ul className="tap-risks">
            {t.risks.map((r, i) => (
              <li key={i} className={`tap-risk tap-risk--${r.level}`}>
                <span className="tap-risk-level">{r.level}</span>
                <div className="tap-risk-body">
                  <div className="tap-risk-title">{r.title}</div>
                  <div className="tap-risk-why">{r.why}</div>
                </div>
              </li>
            ))}
          </ul>
        </Section>

        {/* DROP IN */}
        <Section title="Where to drop in" hint="suggested based on what's hot for your read" serifAI={serifAI} className="tap-section--wide">
          <div className="tap-dropin">
            {t.dropIn.map((d, i) => (
              <button key={i} className={`tap-drop tap-drop--${d.activity}`}>
                <span className="tap-drop-chan">{d.channel}</span>
                <span className="tap-drop-read">{d.read}</span>
                <span className="tap-drop-cta">drop in {I.chevRight}</span>
              </button>
            ))}
          </div>
        </Section>
      </div>

      <footer className="tap-foot">
        <div className="tap-foot-meta">
          <span className="tap-foot-spark" />
          <span>woven from 7 channels · 184 messages · 41 PRs · {t.cadence.decisions} decisions · {t.cadence.incidents} incident</span>
        </div>
        <div className="tap-foot-actions">
          <button className="tap-foot-btn">Schedule weekly</button>
          <button className="tap-foot-btn">Export to leadership channel</button>
          <button className="tap-foot-btn tap-foot-btn--primary" onClick={onClose}>Mark caught up</button>
        </div>
      </footer>
    </div>
  );
}

// ─── helpers
function Section({ title, hint, children, serifAI, priority = -1, className = '' }) {
  return (
    <section className={`tap-section ${className} ${priority === 0 ? 'tap-section--priority' : ''}`}>
      <header className="tap-section-hd">
        <h3 className={`tap-section-title ${serifAI ? 'is-serif' : ''}`}>{title}</h3>
        <span className="tap-section-hint">{hint}</span>
      </header>
      {children}
    </section>
  );
}

function Cadence({ c }) {
  const cells = [
    { v: c.shipped,    k: 'shipped' },
    { v: c.prsMerged,  k: 'merges' },
    { v: c.decisions,  k: 'decisions' },
    { v: c.incidents,  k: 'incidents' },
  ];
  return (
    <div className="tap-cadence">
      {cells.map((cell, i) => (
        <div key={i} className="tap-cadence-cell">
          <div className="tap-cadence-v">{cell.v}</div>
          <div className="tap-cadence-k">{cell.k}</div>
        </div>
      ))}
      <div className="tap-cadence-cell tap-cadence-cell--mttr">
        <div className="tap-cadence-v">{c.mttr}</div>
        <div className="tap-cadence-k">mttr</div>
      </div>
    </div>
  );
}

window.Tapestry = Tapestry;
