// The Reduction · efdp's workbench
// Quiet, mono-forward, low-friction. Every packaged idea is sliced into five
// lenses (Principle / Shape / Mechanism / Edges / Ask) so juniors, seniors,
// principals, POs, and SMEs can pick up the exact layer that fits their work.

const LENS_ORDER = ['principle', 'shape', 'mechanism', 'edges', 'ask'];

const AUDIENCE_NAMES = {
  jr:  'junior',
  sr:  'senior',
  pr:  'principal',
  po:  'product owner',
  sme: 'subject expert',
  team: 'team',
  everyone: 'everyone',
};

function Reduction({ serifAI, onClose }) {
  const { REDUCTION, USERS } = window.TENUN;
  const efdp = USERS.efdp;

  return (
    <div className="red">
      {/* Masthead */}
      <header className="red-mast">
        <div className="red-mast-l">
          <div className="red-mast-eyebrow">
            <span className="red-mast-mark">▽</span>
            <span>the reduction · efdp's workbench</span>
          </div>
          <h1 className={`red-mast-title ${serifAI ? 'is-serif' : ''}`}>
            Boil it down. Hand it off clean.
          </h1>
          <p className="red-mast-sub">
            One thing today. Three in the pot. Three tensions still circling. Four carried.
          </p>
        </div>
        <div className="red-mast-r">
          <LensLegend />
        </div>
      </header>

      {/* Today's reduction */}
      <section className="red-today">
        <div className="red-today-hd">
          <div className="red-today-eyebrow">
            <span className="red-today-pulse" />
            {REDUCTION.today.eyebrow}
          </div>
          <div className="red-today-actions">
            <span className="red-today-state">drafting · 14 inputs distilled</span>
            <button className="red-today-btn">Save draft</button>
            <button className="red-today-btn red-today-btn--primary">Package & share</button>
          </div>
        </div>
        <h2 className={`red-today-title ${serifAI ? 'is-serif' : ''}`}>
          {REDUCTION.today.title}
        </h2>

        <div className="red-today-grid">
          {/* Raw input column */}
          <aside className="red-raw">
            <div className="red-raw-k">Raw</div>
            <ul className="red-raw-list">
              <li><span className="red-raw-n">14</span><span>messages</span></li>
              <li><span className="red-raw-n">3</span><span>threads</span></li>
              <li><span className="red-raw-n">2</span><span>customer reports</span></li>
              <li><span className="red-raw-n">1</span><span>conversation with Claude</span></li>
            </ul>
            <div className="red-raw-k red-raw-k--later">From</div>
            <ul className="red-raw-channels">
              {REDUCTION.today.raw.channels.map((c) => (
                <li key={c}>{c}</li>
              ))}
            </ul>
            <div className="red-raw-note">
              <div className="red-raw-note-k">efdp's note</div>
              <p>{REDUCTION.today.note}</p>
            </div>
          </aside>

          {/* The 5-lens stack — the hero */}
          <div className="red-lenses red-lenses--today">
            {LENS_ORDER.map((lensId) => (
              <LensBand
                key={lensId}
                lensId={lensId}
                lens={REDUCTION.today.lenses[lensId]}
                editable
              />
            ))}
          </div>
        </div>
      </section>

      {/* In the pot */}
      <section className="red-pot">
        <SectionHd
          title="In the pot"
          hint={`${REDUCTION.potIdeas.length} ideas · ${REDUCTION.potIdeas.filter(i => i.stage === 'packaged').length} ready to hand off`}
          serifAI={serifAI}
        />
        <div className="red-pot-grid">
          {REDUCTION.potIdeas.map((idea) => (
            <PotCard key={idea.id} idea={idea} />
          ))}
        </div>
      </section>

      {/* Open tensions */}
      <section className="red-tensions">
        <SectionHd
          title="Tensions"
          hint="not yet resolved · the part that asks instead of answers"
          serifAI={serifAI}
        />
        <ul className="red-tension-list">
          {REDUCTION.tensions.map((t, i) => (
            <li key={i} className={`red-tension red-tension--${t.weight}`}>
              <div className="red-tension-vis" aria-hidden="true">
                <svg viewBox="0 0 40 40" width="40" height="40">
                  <path d="M 4 8 H 36" stroke="currentColor" strokeWidth="1" opacity="0.4" />
                  <path d="M 4 16 H 36" stroke="currentColor" strokeWidth="1" opacity="0.4" />
                  <path d="M 4 24 H 16" stroke="currentColor" strokeWidth="1.5" />
                  <path d="M 24 24 H 36" stroke="currentColor" strokeWidth="1.5" />
                  <path d="M 18 21 L 22 27" stroke="var(--accent)" strokeWidth="1.5" />
                  <path d="M 22 21 L 18 27" stroke="var(--accent)" strokeWidth="1.5" />
                  <path d="M 4 32 H 36" stroke="currentColor" strokeWidth="1" opacity="0.4" />
                </svg>
              </div>
              <div className="red-tension-body">
                <div className="red-tension-title">{t.title}</div>
                <div className="red-tension-why">{t.why}</div>
                {t.related.length > 0 && (
                  <div className="red-tension-rel">
                    related: {t.related.map((r) => (
                      <span key={r} className="red-tension-rel-tag">{r}</span>
                    ))}
                  </div>
                )}
              </div>
            </li>
          ))}
        </ul>
      </section>

      {/* Carried */}
      <section className="red-carried">
        <SectionHd
          title="Carried"
          hint="packaged and owned by someone else now"
          serifAI={serifAI}
        />
        <ul className="red-carry-list">
          {REDUCTION.carried.map((c, i) => (
            <li key={i} className={`red-carry ${c.mine ? 'is-mine' : ''}`}>
              <span className="red-carry-strand" />
              <div className="red-carry-body">
                <div className="red-carry-title">{c.title}</div>
                <div className="red-carry-state">{c.state}</div>
              </div>
              <div className="red-carry-owner">
                <span className="red-carry-av" style={{ background: USERS[c.owner].color }}>
                  {USERS[c.owner].initial}
                </span>
                <span>{USERS[c.owner].name}</span>
              </div>
              <span className="red-carry-since">{c.since}</span>
            </li>
          ))}
        </ul>
      </section>
    </div>
  );
}

// ───────── Lens band — the hero atom ─────────
function LensBand({ lensId, lens, idea, editable, dense }) {
  const def = window.TENUN_LENS_DEFS.find((d) => d.id === lensId);
  const stateClass = `is-${lens.state}`;
  const pickupRole = idea?.pickup?.[lensId];
  return (
    <div className={`lens lens--${lensId} lens-${stateClass} ${dense ? 'lens--dense' : ''}`}>
      <div className="lens-gutter">
        <span className="lens-sym">{def.symbol}</span>
        <span className="lens-label">{def.label}</span>
        <div className="lens-audience">
          {def.audience.map((a) => (
            <span key={a} className={`lens-aud lens-aud--${a}`}>{a}</span>
          ))}
        </div>
      </div>
      <div className="lens-body">
        <p className={`lens-text lens-text--${lens.state}`}>{lens.text}</p>
        {pickupRole && (
          <div className="lens-pickup">
            <span className="lens-pickup-k">pickup</span>
            <span className="lens-pickup-role">→ {AUDIENCE_NAMES[pickupRole]}</span>
          </div>
        )}
      </div>
      <div className="lens-state-dot" title={lens.state} />
    </div>
  );
}

// ───────── Pot card — packaged ideas ─────────
function PotCard({ idea }) {
  return (
    <article className={`pot pot--${idea.stage}`}>
      <header className="pot-hd">
        <div className="pot-hd-l">
          <span className="pot-domain">{idea.domain}</span>
          <h3 className="pot-title">{idea.title}</h3>
        </div>
        <span className={`pot-stage pot-stage--${idea.stage}`}>
          <span className="pot-stage-dot" />
          {idea.stage}
        </span>
      </header>
      <div className="pot-lenses">
        {LENS_ORDER.map((lensId) => (
          <LensBand key={lensId} lensId={lensId} lens={idea.lenses[lensId]} idea={idea} dense />
        ))}
      </div>
      <footer className="pot-foot">
        <div className="pot-foot-progress">
          {LENS_ORDER.map((lensId) => (
            <span key={lensId} className={`pot-prog pot-prog--${idea.lenses[lensId].state}`} title={lensId} />
          ))}
        </div>
        <div className="pot-foot-actions">
          <button className="pot-act">Open package</button>
          {idea.stage === 'packaged' && (
            <button className="pot-act pot-act--primary">Hand off</button>
          )}
        </div>
      </footer>
    </article>
  );
}

// ───────── helpers ─────────
function SectionHd({ title, hint, serifAI }) {
  return (
    <header className="red-section-hd">
      <h3 className={`red-section-title ${serifAI ? 'is-serif' : ''}`}>{title}</h3>
      <span className="red-section-hint">{hint}</span>
    </header>
  );
}

function LensLegend() {
  return (
    <div className="lens-legend">
      <div className="lens-legend-k">Lenses</div>
      <ul>
        {window.TENUN_LENS_DEFS.map((d) => (
          <li key={d.id}>
            <span className="lens-legend-sym">{d.symbol}</span>
            <span className="lens-legend-label">{d.label}</span>
            <span className="lens-legend-aud">{d.audience.join(' · ')}</span>
          </li>
        ))}
      </ul>
      <div className="lens-legend-foot">
        <span className="lens-legend-dot lens-legend-dot--firm" /> firm
        <span className="lens-legend-dot lens-legend-dot--sketched" /> sketched
        <span className="lens-legend-dot lens-legend-dot--open" /> open
      </div>
    </div>
  );
}

window.Reduction = Reduction;
