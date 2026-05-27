// The Expo · dave's station
// The PO's surface: where customer voice flows in, gets clustered into themes,
// shaped into Orders, and handed to the kitchen. When work walks, the original
// voice rides back to the customer.
//
// Three movements, top to bottom: LISTEN → SHAPE → HAND OVER.

const SENTIMENT_COLOR = {
  positive: 'jade',
  request:  'gold',
  mixed:    'copper',
  neutral:  'mute',
  negative: 'copper',
  risk:     'rose',
};

const VOICE_KIND_LABEL = {
  support:   'support',
  call:      'call',
  nps:       'NPS',
  interview: 'interview',
  'in-app':  'in-app',
};

function Expo({ serifAI, onClose }) {
  const { EXPO, CUSTOMERS, USERS, IN_SERVICE } = window.TENUN;
  const [filter, setFilter] = React.useState({ customer: 'all', sentiment: 'all' });
  const [pinnedTheme, setPinnedTheme] = React.useState(null);

  const dave = USERS.dave;
  const voiceMap = Object.fromEntries(EXPO.voice.map((v) => [v.id, v]));
  const themeMap = Object.fromEntries(EXPO.themes.map((t) => [t.id, t]));

  const filteredVoice = EXPO.voice.filter((v) => {
    if (filter.customer !== 'all' && v.customer !== filter.customer) return false;
    if (filter.sentiment !== 'all' && v.sentiment !== filter.sentiment) return false;
    return true;
  });

  // Group voice by customer
  const voiceByCustomer = filteredVoice.reduce((acc, v) => {
    (acc[v.customer] = acc[v.customer] || []).push(v);
    return acc;
  }, {});

  const tickers = {
    voiceToday: EXPO.voice.length,
    themes: EXPO.themes.filter(t => t.state !== 'meta').length,
    shaping: EXPO.orders.filter(o => o.state === 'shaping' || o.state === 'drafted').length,
    onTheLine: EXPO.orders.filter(o => o.state === 'pushed').length,
  };

  return (
    <div className="expo">
      {/* Masthead */}
      <header className="expo-mast">
        <div className="expo-mast-l">
          <div className="expo-mast-eyebrow">
            <span className="expo-mast-mark">◇</span>
            <span>the expo · dave's station</span>
          </div>
          <h1 className="expo-mast-title">Listen. Shape. Hand over.</h1>
          <p className="expo-mast-sub">
            {tickers.voiceToday} voices this week · {tickers.themes} themes · {tickers.shaping} shaping · {tickers.onTheLine} on the line
          </p>
        </div>
        <div className="expo-mast-r">
          <CustomerStrip customers={CUSTOMERS} />
        </div>
      </header>

      {/* 1. LISTEN — raw customer voice */}
      <section className="expo-listen">
        <SectionHd title="Listening" hint="raw voices from the front of house" />
        <div className="expo-filters">
          <span className="expo-filters-k">filter</span>
          <button className={`expo-chip ${filter.customer==='all' ? 'is-on' : ''}`} onClick={() => setFilter({...filter, customer: 'all'})}>all customers</button>
          {Object.values(CUSTOMERS).map((c) => (
            <button key={c.id} className={`expo-chip ${filter.customer === c.id ? 'is-on' : ''}`}
                    onClick={() => setFilter({...filter, customer: c.id})}>
              <span className="expo-chip-dot" style={{ background: c.health === 'healthy' ? 'var(--ok)' : 'var(--error)' }} />
              &amp;{c.name}
            </button>
          ))}
          <span className="expo-filters-sep">·</span>
          {['all','positive','request','mixed','negative','risk'].map((s) => (
            <button key={s} className={`expo-chip ${filter.sentiment === s ? 'is-on' : ''}`}
                    onClick={() => setFilter({...filter, sentiment: s})}>
              {s === 'all' ? 'all sentiment' : s}
            </button>
          ))}
        </div>

        <div className="expo-voice-grid">
          {Object.entries(voiceByCustomer).map(([cid, voices]) => {
            const c = CUSTOMERS[cid];
            return (
              <div key={cid} className={`expo-voice-grp expo-voice-grp--${c.health}`}>
                <div className="expo-voice-grp-hd">
                  <div className="expo-voice-grp-name">&amp;{c.name}</div>
                  <div className="expo-voice-grp-meta">
                    <span>{c.tier}</span>
                    <span className="expo-voice-grp-dot">·</span>
                    <span>{c.arr} ARR</span>
                    <span className="expo-voice-grp-dot">·</span>
                    <span className={`expo-voice-grp-health expo-voice-grp-health--${c.health}`}>{c.health}</span>
                    {c.renewalIn && (
                      <><span className="expo-voice-grp-dot">·</span>
                      <span className="expo-voice-grp-renew">renewal in {c.renewalIn}</span></>
                    )}
                  </div>
                </div>
                <div className="expo-voice-list">
                  {voices.map((v) => (
                    <VoiceCard key={v.id} v={v} themeMap={themeMap} />
                  ))}
                </div>
              </div>
            );
          })}
        </div>
      </section>

      {/* 2. SHAPE — themes (clusters) and Dave's drafts */}
      <section className="expo-shape">
        <SectionHd title="Shaping" hint="patterns in the voice · drafts on the pad" />
        <div className="expo-themes">
          {EXPO.themes.filter(t => t.state !== 'meta').map((t) => (
            <ThemeCard key={t.id} theme={t} voiceMap={voiceMap}
                       order={EXPO.orders.find(o => o.id === t.orderId)}
                       isPinned={pinnedTheme === t.id}
                       onPin={() => setPinnedTheme(pinnedTheme === t.id ? null : t.id)} />
          ))}
        </div>

        {/* Draft Order — the demo moment. A shaping order with voice attached. */}
        <OrderDraft order={EXPO.orders.find(o => o.id === 'o-loom-export')}
                    voiceMap={voiceMap} />
      </section>

      {/* 3. HAND OVER — on the line + walked */}
      <section className="expo-handover">
        <SectionHd title="On the line" hint="orders in the work stream · walked back to customers" />
        <div className="expo-orders">
          {EXPO.orders.filter(o => o.state === 'pushed' || o.state === 'drafted').map((o) => (
            <OrderRow key={o.id} order={o} voiceMap={voiceMap} />
          ))}
          <div className="expo-orders-divider">
            <span>walked</span>
          </div>
          {EXPO.orders.filter(o => o.state === 'walked').map((o) => (
            <OrderRow key={o.id} order={o} voiceMap={voiceMap} walked />
          ))}
        </div>
      </section>
    </div>
  );
}

// ─────────── Voice card ───────────
function VoiceCard({ v, themeMap }) {
  const { USERS, CUSTOMERS } = window.TENUN;
  const theme = themeMap[v.themeId];
  const sentClass = `is-${SENTIMENT_COLOR[v.sentiment] || 'mute'}`;
  return (
    <article className={`voice ${sentClass}`}>
      <div className="voice-quote-mark">"</div>
      <p className="voice-text">{v.text}</p>
      <footer className="voice-foot">
        <div className="voice-who">
          <strong>{v.who}</strong>
          <span className="voice-role"> · {v.role}</span>
        </div>
        <div className="voice-meta">
          <span className={`voice-kind voice-kind--${v.kind}`}>{VOICE_KIND_LABEL[v.kind] || v.kind}</span>
          <span className="voice-dot">·</span>
          <span className="voice-when">{v.when}</span>
          <span className="voice-dot">·</span>
          <span className={`voice-sent voice-sent--${v.sentiment}`}>{v.sentiment}</span>
        </div>
      </footer>
      {theme && (
        <div className="voice-theme">
          <span className="voice-theme-arrow">→</span>
          <span className="voice-theme-name">{theme.title}</span>
          {theme.state === 'shaped' && <span className="voice-theme-state">shaped</span>}
          {theme.state === 'shipped' && <span className="voice-theme-state voice-theme-state--shipped">shipped</span>}
        </div>
      )}
    </article>
  );
}

// ─────────── Theme card ───────────
function ThemeCard({ theme, voiceMap, order, isPinned, onPin }) {
  const { CUSTOMERS, IN_SERVICE } = window.TENUN;
  const workItem = order?.workItemId ? IN_SERVICE.items.find(w => w.id === order.workItemId) : null;
  return (
    <article className={`theme theme--${theme.state} ${isPinned ? 'is-pinned' : ''}`} onClick={onPin}>
      <header className="theme-hd">
        <h4 className="theme-title">{theme.title}</h4>
        <span className={`theme-state theme-state--${theme.state}`}>{theme.state}</span>
      </header>
      <div className="theme-meta">
        <span className="theme-count">{theme.voiceIds.length} voice{theme.voiceIds.length === 1 ? '' : 's'}</span>
        <span className="theme-dot">·</span>
        <div className="theme-customers">
          {theme.customers.map((cid) => (
            <span key={cid} className="theme-cust">&amp;{CUSTOMERS[cid].name}</span>
          ))}
        </div>
      </div>
      {theme.note && <p className="theme-note">{theme.note}</p>}
      {workItem && (
        <div className="theme-link">
          <span className="theme-link-k">on the line</span>
          <span className="theme-link-v">{workItem.title} · {workItem.state}</span>
        </div>
      )}
      {isPinned && (
        <div className="theme-voices">
          {theme.voiceIds.map((vid) => {
            const v = voiceMap[vid];
            return (
              <div key={vid} className="theme-voice">
                <span className="theme-voice-mark">"</span>
                <span className="theme-voice-text">{v.text}</span>
                <span className="theme-voice-who">{v.who}</span>
              </div>
            );
          })}
        </div>
      )}
    </article>
  );
}

// ─────────── Order draft — the design hero ───────────
function OrderDraft({ order, voiceMap }) {
  if (!order) return null;
  const { CUSTOMERS } = window.TENUN;
  return (
    <article className="draft">
      <header className="draft-hd">
        <div className="draft-hd-l">
          <span className="draft-eyebrow">draft order · shaping</span>
          <h3 className="draft-title">{order.title}</h3>
        </div>
        <div className="draft-hd-r">
          <span className="draft-size">{order.size}</span>
          {order.proposedFor && <span className="draft-when">{order.proposedFor}</span>}
        </div>
      </header>

      <div className="draft-body">
        {/* WHY — anchored to specific voice quotes */}
        <div className="draft-row">
          <div className="draft-k">Why</div>
          <div className="draft-v">
            <p className="draft-why">{order.why}</p>
            <div className="draft-evidence">
              {order.voiceIds.map((vid) => {
                const v = voiceMap[vid];
                return (
                  <div key={vid} className="draft-quote">
                    <span className="draft-quote-mark">"</span>
                    <span className="draft-quote-text">{v.text}</span>
                    <span className="draft-quote-attr">
                      <strong>{v.who}</strong> · {v.role} · &amp;{CUSTOMERS[v.customer].name} · {v.when}
                    </span>
                  </div>
                );
              })}
            </div>
          </div>
        </div>

        {/* WHAT */}
        <div className="draft-row">
          <div className="draft-k">What</div>
          <div className="draft-v">
            <p className="draft-what">{order.what}</p>
          </div>
        </div>

        {/* SO THAT */}
        <div className="draft-row">
          <div className="draft-k">So that</div>
          <div className="draft-v">
            <p className="draft-sothat">{order.soThat}</p>
          </div>
        </div>
      </div>

      <footer className="draft-foot">
        <span className="draft-foot-meta">
          {order.customers.map((cid) => (
            <span key={cid} className="draft-foot-cust">&amp;{CUSTOMERS[cid].name}</span>
          ))}
          <span> · voice carries forward</span>
        </span>
        <div className="draft-foot-actions">
          <button className="draft-act">Save draft</button>
          <button className="draft-act">Slice into smaller orders</button>
          <button className="draft-act draft-act--primary">Push to the line</button>
        </div>
      </footer>
    </article>
  );
}

// ─────────── Order row (pushed / walked) ───────────
function OrderRow({ order, voiceMap, walked }) {
  const { CUSTOMERS, IN_SERVICE, USERS } = window.TENUN;
  const workItem = order.workItemId ? IN_SERVICE.items.find(w => w.id === order.workItemId) : null;
  return (
    <article className={`order-row order-row--${order.state} ${walked ? 'is-walked' : ''}`}>
      <div className="order-row-strand" />
      <div className="order-row-body">
        <header className="order-row-hd">
          <h4 className="order-row-title">{order.title}</h4>
          <div className="order-row-tags">
            {order.customers.map((cid) => (
              <span key={cid} className="order-row-cust">&amp;{CUSTOMERS[cid].name}</span>
            ))}
            <span className={`order-row-state order-row-state--${order.state}`}>{order.state}</span>
          </div>
        </header>
        <p className="order-row-why">{order.why}</p>
        <div className="order-row-voices">
          <span className="order-row-voices-k">voice carried</span>
          {order.voiceIds.map((vid) => {
            const v = voiceMap[vid];
            return (
              <span key={vid} className="order-row-voice" title={`${v.who} · ${v.when}`}>
                <span className="order-row-voice-mark">"</span>
                {v.text.length > 60 ? v.text.slice(0, 60) + '…' : v.text}
              </span>
            );
          })}
        </div>
        {workItem && (
          <div className="order-row-link">
            <span className="order-row-link-k">in stream</span>
            <span className="order-row-link-v">{workItem.title}</span>
            <span className="order-row-link-state">{workItem.state} · {workItem.moved}</span>
          </div>
        )}
        {walked && order.tellThem && (
          <div className="order-row-tell">
            <span className="order-row-tell-k">tell them</span>
            {order.tellThem.map((cid) => (
              <button key={cid} className="order-row-tell-btn">
                send to &amp;{CUSTOMERS[cid].name} CSM
              </button>
            ))}
            <button className="order-row-tell-btn order-row-tell-btn--primary">
              draft changelog post
            </button>
          </div>
        )}
      </div>
    </article>
  );
}

// ─────────── Customer strip ───────────
function CustomerStrip({ customers }) {
  return (
    <div className="expo-cust-strip">
      <div className="expo-cust-strip-k">Customers</div>
      <div className="expo-cust-strip-list">
        {Object.values(customers).map((c) => (
          <div key={c.id} className={`expo-cust expo-cust--${c.health}`}>
            <div className="expo-cust-name">&amp;{c.name}</div>
            <div className="expo-cust-arr">{c.arr} · {c.tier}</div>
            <div className={`expo-cust-health expo-cust-health--${c.health}`}>
              <span className="expo-cust-dot" />
              {c.health === 'healthy' ? 'healthy' : 'at risk'}
              {c.renewalIn && <span className="expo-cust-renew"> · renewal {c.renewalIn}</span>}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

// ─────────── helpers ───────────
function SectionHd({ title, hint }) {
  return (
    <header className="expo-section-hd">
      <h3 className="expo-section-title">{title}</h3>
      <span className="expo-section-hint">{hint}</span>
    </header>
  );
}

window.Expo = Expo;
