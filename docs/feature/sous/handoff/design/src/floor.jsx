// The Floor · mina's station
// CSM surface. Three movements: read the room → spot moments → carry shipped
// work back. Customer-relationship lens. Warm, paced, not dashboardy.

const HEALTH_COLOR = { healthy: 'jade', 'at-risk': 'rose', neutral: 'mute' };
const RENEWAL_PROB_LABEL = { 'high': 'high · likely', 'at-risk': 'at risk', 'med': 'mixed' };
const MOMENT_HEAT_COPY = { hot: 'now', warm: 'this week', cool: 'when ready' };

function Floor({ serifAI, onClose }) {
  const { FLOOR, CUSTOMERS, USERS, IN_SERVICE } = window.TENUN;
  const mina = USERS.mina;

  return (
    <div className="floor">
      {/* Masthead */}
      <header className="floor-mast">
        <div className="floor-mast-l">
          <div className="floor-mast-eyebrow">
            <span className="floor-mast-mark">♢</span>
            <span>the floor · mina's station</span>
          </div>
          <h1 className="floor-mast-title">Read the room. Pace the touches. Carry the wins.</h1>
          <p className="floor-mast-sub">
            3 accounts · {FLOOR.pulse.callsThisWeek} calls this week · {FLOOR.pulse.voicesThisWeek} voices captured
          </p>
        </div>
        <div className="floor-mast-r">
          <Pulse pulse={FLOOR.pulse} />
        </div>
      </header>

      {/* Health tiles — at-a-glance */}
      <section className="floor-room">
        <SectionHd title="The room" hint="reading customer health, paced by relationship not metrics" />
        <div className="floor-room-grid">
          {Object.values(CUSTOMERS).map((c) => (
            <CustomerTile key={c.id} customer={c} fromKitchen={FLOOR.fromKitchen.filter(k => {
              const wi = IN_SERVICE.items.find(w => w.id === k.workItemId);
              return wi && wi.people && (wi.evidence || []).some(e => e.kind === 'customer' && e.label.toLowerCase().includes(c.name.split(' ')[0].toLowerCase()));
            })} />
          ))}
        </div>
      </section>

      {/* Moments — opportunities and risks happening now */}
      <section className="floor-moments">
        <SectionHd title="Moments" hint="what wants a response right now" />
        <div className="floor-moments-list">
          {FLOOR.moments.map((m, i) => (
            <MomentCard key={i} moment={m} />
          ))}
        </div>
      </section>

      {/* Call Sheet */}
      <section className="floor-calls">
        <SectionHd title="The call sheet" hint="who needs a touch, and why" />
        <div className="floor-calls-grid">
          <CallColumn title="Today" calls={FLOOR.callSheet.today} kind="today" />
          <CallColumn title="This week" calls={FLOOR.callSheet.thisWeek} kind="upcoming" />
          <RecentCalls calls={FLOOR.callSheet.recent} />
        </div>
      </section>

      {/* Renewals + expansion calendar */}
      <section className="floor-renewals">
        <SectionHd title="Renewals & expansion" hint="ARR at stake, paced out" />
        <div className="floor-renew-list">
          {FLOOR.renewals.map((r, i) => (
            <RenewalRow key={i} renewal={r} />
          ))}
        </div>
      </section>

      {/* From the kitchen — what to carry back */}
      <section className="floor-kitchen">
        <SectionHd title="From the kitchen" hint="walked work touching your accounts · what to say, who to tell" />
        <div className="floor-kitchen-list">
          {FLOOR.fromKitchen.map((k, i) => (
            <KitchenRow key={i} item={k} />
          ))}
        </div>
      </section>
    </div>
  );
}

// ─────────── Pulse band ───────────
function Pulse({ pulse }) {
  return (
    <div className="floor-pulse">
      <div className="floor-pulse-k">Pulse · 7d</div>
      <div className="floor-pulse-grid">
        <div className="floor-pulse-cell">
          <div className="floor-pulse-v">{pulse.nps7d}</div>
          <div className="floor-pulse-l">NPS <span className="floor-pulse-trend">{pulse.npsTrend}</span></div>
        </div>
        <div className="floor-pulse-cell floor-pulse-cell--risk">
          <div className="floor-pulse-v">{pulse.arrAtRisk}</div>
          <div className="floor-pulse-l">ARR at risk</div>
        </div>
        <div className="floor-pulse-cell floor-pulse-cell--ok">
          <div className="floor-pulse-v">{pulse.arrUpside}</div>
          <div className="floor-pulse-l">expansion pipe</div>
        </div>
      </div>
    </div>
  );
}

// ─────────── Customer tile ───────────
function CustomerTile({ customer: c }) {
  return (
    <article className={`floor-tile floor-tile--${c.health}`}>
      <header className="floor-tile-hd">
        <div className="floor-tile-name">&amp;{c.name}</div>
        <div className={`floor-tile-trend floor-tile-trend--${c.trend7d}`}>
          {c.trend7d === 'up' && '↑'}
          {c.trend7d === 'down' && '↓'}
          {c.trend7d === 'flat' && '→'}
          <span>7d</span>
        </div>
      </header>
      <div className="floor-tile-meta">
        <span>{c.tier}</span>
        <span className="floor-dot">·</span>
        <span>{c.arr} ARR</span>
      </div>
      <div className={`floor-tile-health floor-tile-health--${c.health}`}>
        <span className="floor-tile-dot" />
        {c.health === 'healthy' ? 'healthy' : 'at risk'}
      </div>
      <div className="floor-tile-rows">
        <div className="floor-tile-row">
          <span className="floor-tile-row-k">last</span>
          <span className="floor-tile-row-v">{c.lastTouch}</span>
        </div>
        <div className="floor-tile-row">
          <span className="floor-tile-row-k">next</span>
          <span className="floor-tile-row-v">{c.nextTouch}</span>
        </div>
        <div className="floor-tile-row">
          <span className="floor-tile-row-k">renew</span>
          <span className="floor-tile-row-v">{c.contractEnd} · <span className="floor-tile-daysout">{c.daysOut}d</span></span>
        </div>
        {c.expansionPotential !== '\u2014' && (
          <div className="floor-tile-row">
            <span className="floor-tile-row-k">upside</span>
            <span className="floor-tile-row-v floor-tile-row-v--ok">{c.expansionPotential}</span>
          </div>
        )}
      </div>
      {c.contacts.length > 0 && (
        <footer className="floor-tile-foot">
          {c.contacts.map((p, i) => (
            <span key={i} className="floor-tile-contact"><strong>{p.name}</strong> · {p.role}</span>
          ))}
        </footer>
      )}
    </article>
  );
}

// ─────────── Moment card ───────────
function MomentCard({ moment: m }) {
  const { CUSTOMERS, IN_SERVICE } = window.TENUN;
  const c = m.customer ? CUSTOMERS[m.customer] : null;
  const work = (m.relatedWork || []).map(id => IN_SERVICE.items.find(w => w.id === id)).filter(Boolean);

  return (
    <article className={`moment moment--${m.kind} moment--heat-${m.heat}`}>
      <div className="moment-rail" />
      <div className="moment-body">
        <header className="moment-hd">
          <div className="moment-tags">
            <span className={`moment-kind moment-kind--${m.kind}`}>{m.kind}</span>
            <span className="moment-heat-copy">{MOMENT_HEAT_COPY[m.heat]}</span>
          </div>
          {c && <span className="moment-cust">&amp;{c.name}</span>}
        </header>
        <h4 className="moment-title">{m.title}</h4>
        <p className="moment-why">{m.why}</p>
        <div className="moment-foot">
          <div className="moment-action">
            <span className="moment-action-k">action</span>
            <span>{m.action}</span>
          </div>
          {work.map((w) => (
            <span key={w.id} className="moment-link">
              <span className="moment-link-k">linked</span>
              <span>{w.title} · {w.state}</span>
            </span>
          ))}
        </div>
      </div>
    </article>
  );
}

// ─────────── Call columns ───────────
function CallColumn({ title, calls, kind }) {
  const { CUSTOMERS } = window.TENUN;
  return (
    <div className={`floor-call-col floor-call-col--${kind}`}>
      <h4 className="floor-call-col-title">{title}</h4>
      {calls.length === 0 ? (
        <div className="floor-call-empty">— nothing scheduled —</div>
      ) : (
        calls.map((call, i) => {
          const c = CUSTOMERS[call.customer];
          return (
            <article key={i} className={`floor-call floor-call--${c.health}`}>
              <div className="floor-call-time">{call.time}</div>
              <div className="floor-call-body">
                <div className="floor-call-cust">&amp;{c.name}</div>
                <div className="floor-call-contact"><strong>{call.contact}</strong> · {call.kind}</div>
                <div className="floor-call-purpose">{call.purpose}</div>
              </div>
            </article>
          );
        })
      )}
    </div>
  );
}

function RecentCalls({ calls }) {
  const { CUSTOMERS } = window.TENUN;
  return (
    <div className="floor-call-col floor-call-col--recent">
      <h4 className="floor-call-col-title">Recent</h4>
      {calls.map((call, i) => {
        const c = CUSTOMERS[call.customer];
        return (
          <article key={i} className="floor-call-recent">
            <header className="floor-call-recent-hd">
              <div className="floor-call-cust">&amp;{c.name}</div>
              <div className="floor-call-when">{call.when}</div>
            </header>
            <div className="floor-call-contact"><strong>{call.contact}</strong> · {call.kind}</div>
            <p className="floor-call-notes">{call.notes}</p>
          </article>
        );
      })}
    </div>
  );
}

// ─────────── Renewal row ───────────
function RenewalRow({ renewal: r }) {
  const { CUSTOMERS } = window.TENUN;
  const c = CUSTOMERS[r.customer];
  const probClass = r.prob === 'at-risk' ? 'is-risk' : r.prob === 'high' ? 'is-ok' : '';
  return (
    <article className={`renew renew--${r.prob}`}>
      <div className="renew-when">
        <div className="renew-date">{r.when}</div>
        <div className="renew-days">{r.daysOut}d</div>
      </div>
      <div className="renew-body">
        <div className="renew-cust">&amp;{c.name}</div>
        <div className="renew-state">{r.state}</div>
      </div>
      <div className="renew-arr">
        <div className="renew-arr-v">{r.arrFmt}</div>
        <div className="renew-arr-k">ARR</div>
      </div>
      <div className={`renew-prob ${probClass}`}>
        <span className="renew-prob-dot" />
        {RENEWAL_PROB_LABEL[r.prob] || r.prob}
      </div>
    </article>
  );
}

// ─────────── Kitchen row — what to carry back ───────────
function KitchenRow({ item: k }) {
  const { IN_SERVICE } = window.TENUN;
  const wi = IN_SERVICE.items.find(w => w.id === k.workItemId);
  if (!wi) return null;
  return (
    <article className={`floor-kit floor-kit--${k.state}`}>
      <div className="floor-kit-strand" />
      <div className="floor-kit-body">
        <header className="floor-kit-hd">
          <h4 className="floor-kit-title">{wi.title}</h4>
          <span className={`floor-kit-state floor-kit-state--${k.state}`}>{k.state}</span>
        </header>
        <p className="floor-kit-tell">{k.tellNotes}</p>
        <div className="floor-kit-actions">
          <div className="floor-kit-whom">
            <span className="floor-kit-whom-k">tell</span>
            {k.tellWhom.map((name, i) => (
              <span key={i} className="floor-kit-name">{name}</span>
            ))}
          </div>
          <div className="floor-kit-acts">
            {k.changelogDrafted && (
              <button className="floor-kit-btn">Changelog drafted ↗</button>
            )}
            {k.readyToSend
              ? <button className="floor-kit-btn floor-kit-btn--primary">Send now</button>
              : <button className="floor-kit-btn">Draft note</button>}
          </div>
        </div>
      </div>
    </article>
  );
}

// ─────────── helpers ───────────
function SectionHd({ title, hint }) {
  return (
    <header className="floor-section-hd">
      <h3 className="floor-section-title">{title}</h3>
      <span className="floor-section-hint">{hint}</span>
    </header>
  );
}

window.Floor = Floor;
