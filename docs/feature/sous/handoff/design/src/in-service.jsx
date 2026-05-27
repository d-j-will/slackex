// In Service · the brigade at work
// Unified live view of every unit of work in flight. Same atoms, different
// prisms — each work item shows a viewer-aware reading. Attention levels
// (act / watch / know / hidden) deliver right-sized help: surfaces what's
// actionable, dims what's just-good-to-know, hides what isn't your altitude.
// Kitchen brigade language throughout — Order / Mise / Pass / Walked.

const STATE_LABELS = {
  order:  { label: 'Order',  sub: 'called in · not started' },
  mise:   { label: 'Mise',   sub: 'in progress · prep' },
  pass:   { label: 'Pass',   sub: 'about to walk · live' },
  walked: { label: 'Walked', sub: 'off the line · shipped' },
};

const KIND_GLYPH = {
  change:   { sym: '▲', label: 'change' },
  decision: { sym: '◊', label: 'decision' },
  idea:     { sym: '○', label: 'idea' },
  fix:      { sym: '✕', label: 'fix' },
  incident: { sym: '!', label: 'incident' },
  hire:     { sym: '+', label: 'hire' },
};

const ATTENTION_RANK = { act: 0, watch: 1, know: 2, hidden: 3 };

// Which viewers should see SLO chips at all? Help where it's needed.
const SLO_AUDIENCE = new Set(['cto', 'em', 'keem']);

function InService({ open, onClose, viewerId, setViewer, serifAI }) {
  const { IN_SERVICE, VIEWERS, USERS } = window.TENUN;
  const [phase, setPhase] = React.useState('ready');
  const [showHidden, setShowHidden] = React.useState(false);
  const [pinnedId, setPinnedId] = React.useState(null);   // a work item opened to its full facet stack

  React.useEffect(() => {
    if (open) {
      setPhase('loading');
      const t = setTimeout(() => setPhase('ready'), 600);
      return () => clearTimeout(t);
    }
  }, [open]);

  React.useEffect(() => {
    if (!open) return;
    const onKey = (e) => { if (e.key === 'Escape') { setPinnedId(null); onClose(); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open, onClose]);

  if (!open) return null;
  const viewer = VIEWERS[viewerId];

  // Apply per-viewer attention. "hidden" items respect a toggle to peek.
  const attentionFor = (item) => item.attention?.[viewerId] || 'know';
  const visible = IN_SERVICE.items.filter((it) => showHidden || attentionFor(it) !== 'hidden');
  const grouped = ['order','mise','pass','walked'].map((s) => ({
    state: s,
    items: visible
      .filter((it) => it.state === s)
      .sort((a, b) => ATTENTION_RANK[attentionFor(a)] - ATTENTION_RANK[attentionFor(b)]),
  }));

  // Tickers — running totals for the day.
  const tickers = computeTickers(IN_SERVICE.items, viewerId);

  return (
    <div className="svc-overlay" role="dialog" aria-label="In Service">
      <div className="svc-backdrop" onClick={onClose} />
      <div className="svc-shell">
        {/* Top bar */}
        <header className="svc-bar">
          <div className="svc-bar-l">
            <button className="svc-back" onClick={onClose} title="Back">{I.chevLeft}</button>
            <div className="svc-bar-brand">
              <TenunMark size={18} />
              <span className="svc-bar-brand-name">Sous</span>
              <span className="svc-bar-brand-slash">/</span>
              <span className={`svc-bar-brand-here ${serifAI ? 'is-serif' : ''}`}>in service</span>
            </div>
            <StateBanner state={IN_SERVICE.state} note={IN_SERVICE.stateNote} />
          </div>
          <div className="svc-bar-r">
            <div className="svc-viewer">
              <span className="svc-viewer-k">Reading as</span>
              <div className="svc-viewer-tabs">
                {Object.values(VIEWERS).map((v) => (
                  <button key={v.id}
                          className={`svc-viewer-tab ${v.id === viewerId ? 'is-active' : ''}`}
                          onClick={() => setViewer(v.id)}>
                    <span className="svc-viewer-av" style={{ background: v.color }}>{v.initial}</span>
                    <span className="svc-viewer-role">{v.role}</span>
                  </button>
                ))}
              </div>
            </div>
            <button className="svc-bar-close" onClick={onClose}>{I.x}</button>
          </div>
        </header>

        {phase === 'loading' ? (
          <div className="svc-loading">
            <LoomLoader size={42} />
            <div className="svc-loading-label">reading the kitchen…</div>
          </div>
        ) : (
          <>
            {/* Tickers — running totals running across the top */}
            <Tickers t={tickers} viewer={viewer} />

            {/* Four columns of work */}
            <div className="svc-cols">
              {grouped.map(({ state, items }) => (
                <Column key={state} state={state} items={items}
                        attentionFor={attentionFor}
                        viewerId={viewerId}
                        onPin={setPinnedId} pinnedId={pinnedId} />
              ))}
            </div>

            {/* Ambient bottom — SLOs (if your concern) + pager + show-hidden toggle */}
            <Ambient viewerId={viewerId}
                     showHidden={showHidden} setShowHidden={setShowHidden}
                     hiddenCount={IN_SERVICE.items.filter(it => attentionFor(it) === 'hidden').length} />
          </>
        )}
      </div>

      {pinnedId && (
        <FacetDrawer id={pinnedId} viewerId={viewerId} onClose={() => setPinnedId(null)} />
      )}
    </div>
  );
}

// ─────────── State banner ───────────
function StateBanner({ state, note }) {
  return (
    <div className={`svc-state svc-state--${state}`}>
      <span className="svc-state-dot" />
      <span className="svc-state-k">{state === 'calm' ? 'all simmering' : state}</span>
      <span className="svc-state-note">{note}</span>
    </div>
  );
}

// ─────────── Tickers ───────────
function computeTickers(items, viewerId) {
  const att = (it) => it.attention?.[viewerId] || 'know';
  const visible = items.filter((it) => att(it) !== 'hidden');
  return {
    forYou:   visible.filter((it) => att(it) === 'act').length,
    watching: visible.filter((it) => att(it) === 'watch').length,
    walked:   items.filter((it) => it.state === 'walked').length,
    onPass:   items.filter((it) => it.state === 'pass').length,
    mise:     items.filter((it) => it.state === 'mise').length,
    order:    items.filter((it) => it.state === 'order').length,
    handsUp:  items.filter((it) => it.handsUp?.to === viewerId).length,
  };
}

function Tickers({ t, viewer }) {
  return (
    <div className="svc-tickers">
      <div className="svc-ticker svc-ticker--for-you">
        <span className="svc-ticker-v">{t.forYou}</span>
        <span className="svc-ticker-k">for you · act</span>
      </div>
      {t.handsUp > 0 && (
        <div className="svc-ticker svc-ticker--hands-up">
          <span className="svc-ticker-v">{t.handsUp}</span>
          <span className="svc-ticker-k">hands up · to you</span>
        </div>
      )}
      <div className="svc-ticker">
        <span className="svc-ticker-v">{t.watching}</span>
        <span className="svc-ticker-k">watching</span>
      </div>
      <div className="svc-ticker svc-ticker--dim">
        <span className="svc-ticker-v">{t.walked}</span>
        <span className="svc-ticker-k">walked today</span>
      </div>
      <div className="svc-ticker-spacer" />
      <div className="svc-ticker svc-ticker--ghost">
        reading as <strong style={{ color: viewer.color }}>{viewer.role}</strong>
      </div>
    </div>
  );
}

// ─────────── Column ───────────
function Column({ state, items, attentionFor, viewerId, onPin, pinnedId }) {
  const label = STATE_LABELS[state];
  return (
    <section className={`svc-col svc-col--${state}`}>
      <header className="svc-col-hd">
        <div className="svc-col-titleline">
          <h3 className="svc-col-title">{label.label}</h3>
          <span className="svc-col-count">{items.length}</span>
        </div>
        <div className="svc-col-sub">{label.sub}</div>
        <div className="svc-col-rail" aria-hidden="true" />
      </header>
      <div className="svc-col-body">
        {items.length === 0 ? (
          <div className="svc-col-empty">— nothing for your altitude —</div>
        ) : (
          items.map((it) => (
            <WorkCard key={it.id} item={it} attention={attentionFor(it)} viewerId={viewerId}
                      onPin={() => onPin(it.id)} isPinned={pinnedId === it.id} />
          ))
        )}
      </div>
    </section>
  );
}

// ─────────── Work card ───────────
function WorkCard({ item, attention, viewerId, onPin }) {
  const { USERS } = window.TENUN;
  const facet = item.facets[viewerId];
  const lead = USERS[item.people.lead];
  const ask = item.askFor?.[viewerId];
  const handsUp = item.handsUp?.to === viewerId ? item.handsUp : null;
  const kindGlyph = KIND_GLYPH[item.kind] || { sym: '·', label: item.kind };
  const compact = attention === 'know';

  return (
    <article className={`svc-card svc-card--${attention} svc-card--${item.kind} ${item.heat ? `svc-card--heat-${item.heat}` : ''} ${compact ? 'svc-card--compact' : ''}`}
             onClick={onPin}
             tabIndex={0}>
      {/* Top: kind, title, attention badge */}
      <header className="svc-card-hd">
        <span className={`svc-kind svc-kind--${item.kind}`} title={kindGlyph.label}>
          {kindGlyph.sym}
        </span>
        <h4 className="svc-card-title">{item.title}</h4>
        {attention === 'act' && (
          <span className="svc-attn svc-attn--act">behind</span>
        )}
        {handsUp && (
          <span className="svc-attn svc-attn--handsup">hands up</span>
        )}
        {item.heat && attention !== 'know' && (
          <span className={`svc-heat svc-heat--${item.heat}`} title={`heat: ${item.heat}`} />
        )}
      </header>

      {!compact && (
        <>
          {/* Facet — the viewer-aware reading */}
          <p className="svc-card-facet">{facet}</p>

          {handsUp && (
            <div className="svc-handsup">
              <span className="svc-handsup-from" style={{ background: USERS[handsUp.from].color }}>
                {USERS[handsUp.from].initial}
              </span>
              <span className="svc-handsup-ask">
                <strong>{USERS[handsUp.from].name}</strong> · {handsUp.ask}
              </span>
            </div>
          )}

          {ask && !handsUp && (
            <div className="svc-ask">
              <span className="svc-ask-k">ask</span>
              <span>{ask}</span>
            </div>
          )}

          {/* Evidence chips */}
          <div className="svc-card-foot">
            <div className="svc-evidence">
              {item.evidence?.slice(0, 3).map((e, i) => (
                <span key={i} className={`svc-ev svc-ev--${e.kind}`}>{e.label}</span>
              ))}
            </div>
            <div className="svc-card-people">
              <span className="svc-lead-av" style={{ background: lead.color }}>{lead.initial}</span>
              {(item.people.supporting || []).map((u) => (
                <span key={u} className="svc-lead-av svc-lead-av--sm" style={{ background: USERS[u].color }}>
                  {USERS[u].initial}
                </span>
              ))}
              <span className="svc-card-moved">{item.moved}</span>
            </div>
          </div>
        </>
      )}

      {compact && (
        <div className="svc-card-compact-meta">
          <span className="svc-lead-av svc-lead-av--sm" style={{ background: lead.color }}>{lead.initial}</span>
          <span className="svc-card-moved">{item.moved}</span>
        </div>
      )}
    </article>
  );
}

// ─────────── Facet drawer — same atom, all prisms ───────────
function FacetDrawer({ id, viewerId, onClose }) {
  const { IN_SERVICE, VIEWERS, USERS } = window.TENUN;
  const item = IN_SERVICE.items.find((w) => w.id === id);
  if (!item) return null;
  const order = ['ceo','cto','em','dave','mina','keem','efdp'];
  return (
    <div className="svc-drawer" role="dialog" onClick={(e) => e.stopPropagation()}>
      <div className="svc-drawer-bg" onClick={onClose} />
      <aside className="svc-drawer-card">
        <header className="svc-drawer-hd">
          <span className={`svc-kind svc-kind--${item.kind}`}>{KIND_GLYPH[item.kind].sym}</span>
          <h3 className="svc-drawer-title">{item.title}</h3>
          <button className="svc-drawer-close" onClick={onClose}>{I.x}</button>
        </header>
        <div className="svc-drawer-meta">
          <span className="svc-drawer-state">{STATE_LABELS[item.state].label.toLowerCase()}</span>
          <span className="svc-drawer-moved">{item.moved}</span>
          <div className="svc-drawer-people">
            <span className="svc-lead-av" style={{ background: USERS[item.people.lead].color }}>
              {USERS[item.people.lead].initial}
            </span>
            <span>{USERS[item.people.lead].name}</span>
            {(item.people.supporting || []).map((u) => (
              <span key={u} className="svc-lead-av svc-lead-av--sm" style={{ background: USERS[u].color }}>
                {USERS[u].initial}
              </span>
            ))}
          </div>
        </div>

        <div className="svc-drawer-prisms">
          <div className="svc-drawer-prisms-k">Same atom · five prisms</div>
          {order.map((vid) => {
            const v = VIEWERS[vid];
            const att = item.attention?.[vid] || 'know';
            const isYou = vid === viewerId;
            if (att === 'hidden') {
              return (
                <div key={vid} className="svc-prism svc-prism--hidden">
                  <span className="svc-prism-tag" style={{ borderColor: v.color, color: v.color }}>{v.role}</span>
                  <em className="svc-prism-text">not at this altitude</em>
                </div>
              );
            }
            return (
              <div key={vid} className={`svc-prism svc-prism--${att} ${isYou ? 'is-you' : ''}`}>
                <span className="svc-prism-tag" style={{ borderColor: v.color, color: v.color }}>{v.role}</span>
                <span className={`svc-prism-att svc-prism-att--${att}`}>{att}</span>
                <p className="svc-prism-text">{item.facets[vid]}</p>
              </div>
            );
          })}
        </div>

        {item.evidence && (
          <footer className="svc-drawer-foot">
            <div className="svc-drawer-evidence">
              {item.evidence.map((e, i) => (
                <span key={i} className={`svc-ev svc-ev--${e.kind}`}>{e.label}</span>
              ))}
            </div>
          </footer>
        )}
      </aside>
    </div>
  );
}

// ─────────── Ambient bottom strip ───────────
function Ambient({ viewerId, showHidden, setShowHidden, hiddenCount }) {
  const { IN_SERVICE, USERS } = window.TENUN;
  const seesSLO = SLO_AUDIENCE.has(viewerId);
  const pager = IN_SERVICE.pager;

  return (
    <footer className="svc-ambient">
      {/* SLOs only for the audience that cares — help where needed */}
      {seesSLO && (
        <div className="svc-ambient-grp">
          <div className="svc-ambient-k">SLO budget</div>
          <div className="svc-slo-strip">
            {IN_SERVICE.slos.map((s, i) => (
              <span key={i} className={`svc-slo svc-slo--${s.state}`} title={`runway · ${s.runway}`}>
                <span className="svc-slo-name">{s.svc}</span>
                <span className="svc-slo-bar">
                  <span className="svc-slo-fill" style={{ width: `${s.budget * 100}%` }} />
                </span>
                <span className="svc-slo-runway">{s.runway}</span>
              </span>
            ))}
          </div>
        </div>
      )}

      <div className="svc-ambient-grp svc-ambient-grp--pager">
        <div className="svc-ambient-k">Pager</div>
        <div className="svc-pager">
          <span className="svc-pager-pri">
            <span className="svc-lead-av" style={{ background: USERS[pager.primary].color }}>{USERS[pager.primary].initial}</span>
            <span><strong>{USERS[pager.primary].name}</strong> · primary · until {pager.until}</span>
          </span>
          <span className="svc-pager-sec">
            secondary <span style={{ color: USERS[pager.secondary].color }}>{USERS[pager.secondary].name}</span>
            <span className="svc-pager-dot">·</span>
            <span>this week: {pager.week.pages} pages · mttr {pager.week.mttrAvg}</span>
          </span>
        </div>
      </div>

      {hiddenCount > 0 && (
        <button className="svc-ambient-hidden" onClick={() => setShowHidden(!showHidden)}>
          {showHidden ? '✕ hide' : `+${hiddenCount} not at your altitude`}
        </button>
      )}
    </footer>
  );
}

window.InService = InService;
