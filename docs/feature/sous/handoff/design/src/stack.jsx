// The Stack · cmdr_keem's perch
// Cartographer + perimeter watcher. Maps Tenun's dependency layers and watches
// every release in the ecosystem that touches them, with his own verdict on
// whether to act. Mono-heavy, table-leaning, dense by design — keem reads fast.

function StackView({ serifAI, onClose }) {
  const { STACK, USERS } = window.TENUN;

  return (
    <div className="stk">
      {/* Masthead */}
      <header className="stk-mast">
        <div className="stk-mast-l">
          <div className="stk-mast-eyebrow">
            <span className="stk-mast-dot" />
            <span>the stack · keem's perch</span>
            <span className="stk-mast-asof">· {STACK.asOf}</span>
          </div>
          <h1 className="stk-mast-title">
            Map the dependencies. Watch the perimeter.
          </h1>
          <p className="stk-mast-sub">
            7 new releases on the horizon · 3 lagging in our stack · 1 critical to plan around.
          </p>
        </div>
        <div className="stk-mast-r">
          <StackKpis />
        </div>
      </header>

      {/* The Horizon — table-style hero */}
      <section className="stk-horizon">
        <SectionHd
          title="On the horizon"
          hint="what the world shipped this week × what we run × my read"
        />
        <table className="stk-hzn">
          <thead>
            <tr>
              <th className="stk-hzn-sev">·</th>
              <th>release</th>
              <th>ours</th>
              <th>impact</th>
              <th>keem's read</th>
              <th className="stk-hzn-when">when</th>
            </tr>
          </thead>
          <tbody>
            {STACK.horizon.map((h, i) => (
              <tr key={i} className={`stk-hzn-row stk-hzn-row--${h.severity}`}>
                <td className="stk-hzn-sev">
                  <span className={`stk-sev stk-sev--${h.severity}`} title={h.severity} />
                </td>
                <td>
                  <div className="stk-hzn-what">{h.what}</div>
                  <div className="stk-hzn-where">{h.where}</div>
                  <div className="stk-hzn-tags">
                    {h.tags.map((t) => <span key={t} className="stk-tag">{t}</span>)}
                  </div>
                </td>
                <td>
                  <div className="stk-hzn-ours">{h.ours}</div>
                </td>
                <td>
                  <div className="stk-hzn-impact">{h.impact}</div>
                </td>
                <td>
                  <div className="stk-hzn-keems">
                    <span className="stk-hzn-quote-open">"</span>{h.keems}<span className="stk-hzn-quote-close">"</span>
                  </div>
                </td>
                <td className="stk-hzn-when">{h.when}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      {/* The Stack proper */}
      <section className="stk-layers-section">
        <SectionHd
          title="The stack"
          hint="what we're built on · current / lag indicated"
        />
        <div className="stk-layers">
          {STACK.layers.map((layer, li) => (
            <div key={li} className="stk-layer">
              <div className="stk-layer-name">{layer.name}</div>
              <div className="stk-layer-items">
                {layer.items.map((it, ii) => (
                  <StackItem key={ii} item={it} />
                ))}
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* Library + Bench side-by-side */}
      <div className="stk-grid">
        <section className="stk-library">
          <SectionHd title="Library" hint="reading · marginalia" />
          <ul className="stk-lib-list">
            {STACK.library.map((l, i) => (
              <li key={i} className={`stk-lib stk-lib--${l.kind}`}>
                <div className="stk-lib-kind">{l.kind}</div>
                <div className="stk-lib-body">
                  <div className="stk-lib-title">{l.title}</div>
                  <div className="stk-lib-where">{l.where}</div>
                  <div className="stk-lib-note">{l.note}</div>
                </div>
                <span className="stk-lib-tag">{l.tag}</span>
              </li>
            ))}
          </ul>
        </section>

        <section className="stk-bench">
          <SectionHd title="Bench" hint="evals I've actually run" />
          <ul className="stk-bench-list">
            {STACK.bench.map((b, i) => (
              <li key={i} className={`stk-bench-row stk-bench-row--${b.kept ? 'kept' : 'shelved'}`}>
                <div className="stk-bench-l">
                  <div className="stk-bench-title">{b.title}</div>
                  <div className="stk-bench-verdict">{b.verdict}</div>
                </div>
                <div className="stk-bench-r">
                  <span className="stk-bench-when">{b.when}</span>
                  <span className={`stk-bench-pill stk-bench-pill--${b.kept ? 'kept' : 'shelved'}`}>
                    {b.kept ? 'kept' : 'shelved'}
                  </span>
                </div>
              </li>
            ))}
          </ul>
        </section>
      </div>

      {/* Chewing — the open questions */}
      <section className="stk-chewing">
        <SectionHd title="Chewing on" hint="questions I haven't answered" />
        <ul className="stk-chew-list">
          {STACK.chewing.map((q, i) => (
            <li key={i} className="stk-chew">
              <span className="stk-chew-q">?</span>
              <span>{q}</span>
            </li>
          ))}
        </ul>
      </section>
    </div>
  );
}

function StackItem({ item }) {
  const lag = item.status === 'lag';
  return (
    <div className={`stk-item ${lag ? 'is-lag' : ''}`}>
      <div className="stk-item-row">
        <span className="stk-item-tech">{item.tech}</span>
        <span className="stk-item-v">{item.v}</span>
        {lag && (
          <span className="stk-item-behind">
            <span className="stk-item-arrow">▸</span>
            <span className="stk-item-behind-v">{item.behind}</span>
          </span>
        )}
      </div>
      <div className="stk-item-meta">
        <span className="stk-item-touch">last touch · {item.lastTouch}</span>
        {item.concern && <span className="stk-item-concern">{item.concern}</span>}
      </div>
    </div>
  );
}

function StackKpis() {
  const STACK = window.TENUN.STACK;
  const totals = STACK.layers.reduce((acc, l) => {
    l.items.forEach((it) => {
      if (it.status === 'lag') acc.lag += 1;
      else acc.current += 1;
    });
    return acc;
  }, { current: 0, lag: 0 });
  const critical = STACK.horizon.filter(h => h.severity === 'critical').length;
  const opp = STACK.horizon.filter(h => h.severity === 'opportunity').length;
  return (
    <div className="stk-kpis">
      <div className="stk-kpi">
        <div className="stk-kpi-v">{totals.current}</div>
        <div className="stk-kpi-k">current</div>
      </div>
      <div className="stk-kpi stk-kpi--lag">
        <div className="stk-kpi-v">{totals.lag}</div>
        <div className="stk-kpi-k">lag</div>
      </div>
      <div className="stk-kpi stk-kpi--crit">
        <div className="stk-kpi-v">{critical}</div>
        <div className="stk-kpi-k">critical</div>
      </div>
      <div className="stk-kpi stk-kpi--opp">
        <div className="stk-kpi-v">{opp}</div>
        <div className="stk-kpi-k">opportunity</div>
      </div>
    </div>
  );
}

function SectionHd({ title, hint }) {
  return (
    <header className="stk-section-hd">
      <h3 className="stk-section-title">{title}</h3>
      <span className="stk-section-hint">{hint}</span>
    </header>
  );
}

window.StackView = StackView;
