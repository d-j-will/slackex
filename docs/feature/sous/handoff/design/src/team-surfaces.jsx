// Team-workflow surfaces: On-the-Loom strip, Decision card, Customer voice,
// Oncall handoff, rich PR unfurl with CI checks, Echo dedup hint.

// ─────────── On the Loom · ambient strip ───────────
function OnTheLoomStrip({ serifAI }) {
  const { ON_THE_LOOM, USERS } = window.TENUN;
  const { trunk, oncall, flags } = ON_THE_LOOM;
  const [expanded, setExpanded] = React.useState(false);

  const primary = USERS[oncall.primary];
  const secondary = USERS[oncall.secondary];
  const author = USERS[trunk.author];

  return (
    <div className={`otl ${expanded ? 'is-expanded' : ''}`}>
      <button className="otl-row" onClick={() => setExpanded(!expanded)}>
        {/* trunk */}
        <div className="otl-cell otl-cell--trunk">
          <div className="otl-cell-label">
            <span className="otl-pulse otl-pulse--gold" />
            <span className={`otl-label ${serifAI ? 'is-serif' : ''}`}>On the loom</span>
          </div>
          <div className="otl-trunk-line">
            <span className="otl-sha">{trunk.sha}</span>
            <span className="otl-trunk-title">{trunk.title}</span>
          </div>
          <div className="otl-progress" aria-label={trunk.stage}>
            <div className="otl-progress-bar" style={{ width: `${trunk.progress * 100}%` }} />
            <div className="otl-progress-weft" />
          </div>
          <div className="otl-trunk-meta">
            <span className="otl-trunk-stage">{trunk.stage}</span>
            <span className="otl-trunk-eta">eta {trunk.eta}</span>
            <span className="otl-trunk-by">by {author.name}</span>
          </div>
        </div>

        {/* oncall */}
        <div className="otl-cell otl-cell--oncall">
          <div className="otl-cell-label">
            <span className="otl-pulse otl-pulse--jade" />
            <span className="otl-label-sm">Oncall</span>
          </div>
          <div className="otl-oncall">
            <span className="otl-av" style={{ background: primary.color }}>{primary.initial}</span>
            <span className="otl-oncall-name">{primary.name}</span>
            <span className="otl-oncall-2nd">+ {secondary.name}</span>
          </div>
          <div className="otl-oncall-until">until {oncall.until}</div>
        </div>

        {/* flags */}
        <div className="otl-cell otl-cell--flags">
          <div className="otl-cell-label">
            <span className="otl-label-sm">Flags</span>
          </div>
          <div className="otl-flags">
            {flags.map((f) => (
              <span key={f.name} className={`otl-flag otl-flag--${f.state}`}>
                <span className="otl-flag-dot" />
                <span className="otl-flag-name">{f.name}</span>
                {f.state === 'canary' && <span className="otl-flag-pct">{Math.round(f.rollout * 100)}%</span>}
              </span>
            ))}
          </div>
        </div>

        <span className="otl-chev">{expanded ? I.chevDown : I.chevRight}</span>
      </button>

      {expanded && (
        <div className="otl-expanded">
          <div className="otl-exp-row">
            <div className="otl-exp-k">Checks</div>
            <div className="otl-exp-v otl-checks">
              {window.TENUN.PR_1842.checks.map((c) => (
                <span key={c.name} className={`otl-check otl-check--${c.state}`}>
                  <span className="otl-check-dot" />
                  <span>{c.name}</span>
                  <span className="otl-check-time">{c.time}</span>
                </span>
              ))}
            </div>
          </div>
          <div className="otl-exp-row">
            <div className="otl-exp-k">Pagers</div>
            <div className="otl-exp-v otl-pagers">0 open · last 7d: 2 (resolved · median MTTR 14m)</div>
          </div>
          <div className="otl-exp-row">
            <div className="otl-exp-k">Window</div>
            <div className="otl-exp-v">freeze in 2h 14m · weekend window starts Fri 17:00</div>
          </div>
        </div>
      )}
    </div>
  );
}

// ─────────── Oncall handoff card ───────────
function OncallHandoff({ from, to, until, notes }) {
  const { USERS } = window.TENUN;
  const f = USERS[from], t = USERS[to];
  return (
    <div className="oncall-card">
      <div className="oncall-card-hd">
        <span className="oncall-card-tag">/oncall handoff</span>
        <span className="oncall-card-until">until {until}</span>
      </div>
      <div className="oncall-card-pass">
        <div className="oncall-side">
          <span className="oncall-av" style={{ background: f.color }}>{f.initial}</span>
          <div className="oncall-side-meta">
            <div className="oncall-side-name">{f.name}</div>
            <div className="oncall-side-role">handing off</div>
          </div>
        </div>
        <svg viewBox="0 0 120 24" width="120" height="24" className="oncall-pass-svg" aria-hidden="true">
          <path d="M5 12 H110" stroke="var(--text-3)" strokeWidth="0.8" strokeDasharray="2 3" />
          <path d="M104 6 L114 12 L104 18" stroke="var(--accent)" strokeWidth="1.5" fill="none" />
          <circle cx="60" cy="12" r="3" fill="var(--accent)">
            <animate attributeName="cx" from="10" to="110" dur="2.4s" repeatCount="indefinite" />
            <animate attributeName="opacity" values="0;1;1;0" dur="2.4s" repeatCount="indefinite" />
          </circle>
        </svg>
        <div className="oncall-side">
          <span className="oncall-av" style={{ background: t.color }}>{t.initial}</span>
          <div className="oncall-side-meta">
            <div className="oncall-side-name">{t.name}</div>
            <div className="oncall-side-role oncall-side-role--now">taking the pager</div>
          </div>
        </div>
      </div>
      <ul className="oncall-notes">
        {notes.map((n, i) => (
          <li key={i} className="oncall-note">
            <span className="oncall-note-dot" />
            <span dangerouslySetInnerHTML={{ __html: n.replace(/`([^`]+)`/g, '<code class="md-code">$1</code>').replace(/&(\w+) \(([^)]+)\)/g, '<span class="md-customer">$2</span>') }} />
          </li>
        ))}
      </ul>
    </div>
  );
}

// ─────────── Decision card ───────────
function DecisionCard({ data }) {
  const { USERS } = window.TENUN;
  const dri = USERS[data.dri];
  return (
    <div className="decision">
      <div className="decision-hd">
        <span className="decision-tag">
          <span className="decision-spark" />
          /decide
        </span>
        <span className="decision-date">{data.date}</span>
      </div>
      <h3 className="decision-title">{data.title}</h3>

      <div className="decision-meta">
        <div className="decision-meta-row">
          <span className="decision-meta-k">DRI</span>
          <span className="decision-dri">
            <span className="decision-av" style={{ background: dri.color }}>{dri.initial}</span>
            <span>{dri.name}</span>
          </span>
        </div>
        <div className="decision-meta-row">
          <span className="decision-meta-k">With</span>
          <span className="decision-stakeholders">
            {data.stakeholders.map((u) => (
              <span key={u} className="decision-av decision-av--sm" style={{ background: USERS[u].color }}>
                {USERS[u].initial}
              </span>
            ))}
          </span>
        </div>
      </div>

      <div className="decision-section">
        <div className="decision-section-k">What</div>
        <div className="decision-section-v">{data.what}</div>
      </div>
      <div className="decision-section">
        <div className="decision-section-k">Why</div>
        <div className="decision-section-v">{data.why}</div>
      </div>
      <div className="decision-section">
        <div className="decision-section-k">Next</div>
        <ul className="decision-next">
          {data.next.map((n, i) => {
            const u = USERS[n.who];
            return (
              <li key={i} className="decision-next-row">
                <span className="decision-av decision-av--sm" style={{ background: u.color }}>{u.initial}</span>
                <span>{n.what}</span>
              </li>
            );
          })}
        </ul>
      </div>

      <footer className="decision-foot">
        <span className="decision-foot-meta">woven from {data.sources.length} thread replies</span>
        <div className="decision-foot-actions">
          <button className="decision-foot-btn">Add to Spool</button>
          <button className="decision-foot-btn">Export</button>
          <button className="decision-foot-btn decision-foot-btn--primary">Pin</button>
        </div>
      </footer>
    </div>
  );
}

// ─────────── Customer voice card ───────────
function CustomerVoice({ ids }) {
  const { CUSTOMERS } = window.TENUN;
  return (
    <div className="customer-row">
      {ids.map((id) => {
        const c = CUSTOMERS[id];
        return (
          <div key={id} className={`customer-card customer-card--${c.health}`}>
            <div className="customer-card-hd">
              <div className="customer-card-mark">
                <span className="customer-card-amp">&amp;</span>
              </div>
              <div>
                <div className="customer-card-name">{c.name}</div>
                <div className="customer-card-tier">{c.tier} · {c.arr} ARR</div>
              </div>
              <div className="customer-card-health">
                <span className={`customer-dot customer-dot--${c.health}`} />
                {c.health === 'healthy' ? 'healthy' : 'at risk'}
              </div>
            </div>
            <div className="customer-card-recent">{c.recent}</div>
            <div className="customer-card-foot">
              <span className="customer-card-csm">CSM: {c.csm}</span>
              <button className="customer-card-cta">Open profile {I.chevRight}</button>
            </div>
          </div>
        );
      })}
    </div>
  );
}

// ─────────── Rich PR unfurl with live CI checks ───────────
function PRCard({ id }) {
  const data = window.TENUN[id];
  const { USERS } = window.TENUN;
  const author = USERS[data.author];

  return (
    <div className="pr-card">
      <div className="pr-card-strand" />
      <div className="pr-card-body">
        <header className="pr-card-hd">
          <span className="pr-card-site">{I.github}<span>GitHub</span></span>
          <span className="pr-card-num">{data.repo}<span className="pr-card-hash">#</span>{data.number}</span>
          <span className="pr-card-state">{data.state}</span>
        </header>
        <h3 className="pr-card-title">{data.title}</h3>
        <div className="pr-card-branch">
          <span className="pr-card-author">
            <span className="pr-card-av" style={{ background: author.color }}>{author.initial}</span>
            {data.author}
          </span>
          <span className="pr-card-branch-line">
            <code>{data.branch}</code>
          </span>
        </div>

        <div className="pr-card-cols">
          <div className="pr-card-col">
            <div className="pr-card-col-k">Reviewers</div>
            <div className="pr-card-reviewers">
              {data.reviewers.map((r) => {
                const u = USERS[r.user];
                return (
                  <span key={r.user} className={`pr-reviewer pr-reviewer--${r.state}`}>
                    <span className="pr-card-av" style={{ background: u.color }}>{u.initial}</span>
                    <span className="pr-reviewer-state">{r.state === 'approved' ? '✓' : '◌'}</span>
                  </span>
                );
              })}
            </div>
          </div>
          <div className="pr-card-col">
            <div className="pr-card-col-k">Diff</div>
            <div className="pr-card-diff">
              <span className="pr-diff-add">+{data.diff.plus}</span>
              <span className="pr-diff-rem">−{data.diff.minus}</span>
              <span className="pr-diff-files">{data.diff.files} files</span>
            </div>
          </div>
        </div>

        <div className="pr-card-checks">
          <div className="pr-card-col-k">Checks</div>
          <div className="pr-checks-grid">
            {data.checks.map((c) => (
              <span key={c.name} className={`pr-check pr-check--${c.state}`}>
                <span className="pr-check-dot" />
                <span className="pr-check-name">{c.name}</span>
                <span className="pr-check-time">{c.time}</span>
              </span>
            ))}
          </div>
        </div>

        <footer className="pr-card-foot">
          <button className="pr-card-cta">View on GitHub {I.chevRight}</button>
          <button className="pr-card-cta pr-card-cta--ok">Ready to merge</button>
        </footer>
      </div>
    </div>
  );
}

// ─────────── Echo dedup hint (composer) ───────────
function EchoHint({ onDismiss, serifAI }) {
  return (
    <div className="echo-hint">
      <span className="echo-hint-wave">
        <svg viewBox="0 0 24 12" width="24" height="12">
          <path d="M1 6 Q4 1 7 6 T13 6 T19 6 T25 6" stroke="currentColor" strokeWidth="1.2" fill="none" />
        </svg>
      </span>
      <span className={`echo-hint-label ${serifAI ? 'is-serif' : ''}`}>
        echo · this was discussed before
      </span>
      <button className="echo-hint-cite">jules · 9 days ago in #deploys</button>
      <span className="echo-hint-sep">·</span>
      <button className="echo-hint-cite">keem · 3w ago in #tenun-bugs-annoyances</button>
      <button className="echo-hint-dismiss" onClick={onDismiss}>{I.x}</button>
    </div>
  );
}

window.OnTheLoomStrip = OnTheLoomStrip;
window.OncallHandoff = OncallHandoff;
window.DecisionCard = DecisionCard;
window.CustomerVoice = CustomerVoice;
window.PRCard = PRCard;
window.EchoHint = EchoHint;
