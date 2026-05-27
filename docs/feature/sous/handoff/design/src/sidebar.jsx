// Sidebar — workspace switcher, channels, DMs, weave activity strip, user footer.

function Sidebar({ activeChannel, onPickChannel, onTogglePalette, onOpenTapestry, onOpenService, viewer, dark, setDark }) {
  const { CHANNELS, DMS, USERS } = window.TENUN;
  const me = USERS.dave;

  return (
    <aside className="sidebar">
      {/* Header: workspace mark */}
      <div className="sb-head">
        <div className="sb-brand">
          <TenunMark size={20} />
          <div className="sb-brand-meta">
            <div className="sb-brand-name">Sous</div>
            <div className="sb-brand-sub">sous · est. 2024</div>
          </div>
        </div>
        <button className="sb-icon-btn" title="New message">
          {I.edit}
        </button>
      </div>

      {/* Quick actions */}
      <div className="sb-quick">
        <button className="sb-quick-btn" onClick={onTogglePalette}>
          {I.search}
          <span>Jump to…</span>
          <kbd>⌘K</kbd>
        </button>
        <button className="sb-tapestry" onClick={onOpenTapestry}>
          <div className="sb-tapestry-mark">
            <span className="sb-tapestry-spark" />
          </div>
          <div className="sb-tapestry-body">
            <div className="sb-tapestry-label">
              {viewer.surface === 'reduction' ? 'The Reduction'
                : viewer.surface === 'stack' ? 'The Stack'
                : viewer.surface === 'expo' ? 'The Expo'
                : viewer.surface === 'floor' ? 'The Floor'
                : 'The Pass'}
              <span className="sb-tapestry-kbd">⌘.</span>
            </div>
            <div className="sb-tapestry-sub">
              reading as <span style={{ color: viewer.color }}>{viewer.role}</span> · {viewer.name}
            </div>
          </div>
        </button>
        <button className="sb-service" onClick={onOpenService}>
          <div className="sb-service-mark">
            <span className="sb-service-pulse" />
          </div>
          <div className="sb-service-body">
            <div className="sb-service-label">
              In Service
              <span className="sb-tapestry-kbd">⌘L</span>
            </div>
            <div className="sb-service-sub">
              the brigade at work
            </div>
          </div>
        </button>
      </div>

      {/* Channels */}
      <div className="sb-section">
        <div className="sb-section-hd">
          <button className="sb-section-toggle">
            {I.chevDown}
            <span>Channels</span>
          </button>
          <div className="sb-section-actions">
            <button className="sb-icon-btn sb-icon-btn--sm" title="Browse">{I.search}</button>
            <button className="sb-icon-btn sb-icon-btn--sm" title="Add channel">{I.plus}</button>
          </div>
        </div>
        <ul className="sb-list">
          {CHANNELS.map((c) => (
            <li key={c.id}>
              <button
                className={`sb-item ${activeChannel === c.id ? 'is-active' : ''} ${c.unread ? 'is-unread' : ''}`}
                onClick={() => onPickChannel(c.id)}
              >
                <span className="sb-item-warp">
                  <WarpActivity value={c.activity} />
                </span>
                <span className="sb-item-hash">#</span>
                <span className="sb-item-name">{c.name}</span>
                {c.unread > 0 && <span className="sb-item-badge">{c.unread}</span>}
              </button>
            </li>
          ))}
        </ul>
      </div>

      {/* Direct messages */}
      <div className="sb-section">
        <div className="sb-section-hd">
          <button className="sb-section-toggle">
            {I.chevDown}
            <span>Direct messages</span>
          </button>
          <div className="sb-section-actions">
            <button className="sb-icon-btn sb-icon-btn--sm" title="New DM">{I.plus}</button>
          </div>
        </div>
        <ul className="sb-list">
          {DMS.map((d) => {
            const u = USERS[d.user];
            return (
              <li key={d.id}>
                <button
                  className={`sb-item sb-item--dm ${activeChannel === `dm:${d.id}` ? 'is-active' : ''}`}
                  onClick={() => onPickChannel(`dm:${d.id}`)}
                >
                  <Avatar user={u} size={20} ring={d.presence} />
                  <span className="sb-item-name">{u.name}</span>
                  {u.status && <span className="sb-item-status-dot" title={u.status} />}
                </button>
              </li>
            );
          })}
          <li>
            <button className="sb-item sb-item--ghost">
              {I.plus}
              <span className="sb-item-name">New message</span>
            </button>
          </li>
        </ul>
      </div>

      {/* AI rail — pinned summaries */}
      <div className="sb-section sb-section--ai">
        <div className="sb-section-hd">
          <button className="sb-section-toggle">
            {I.chevDown}
            <span>Loom <em>· pinned summaries</em></span>
          </button>
        </div>
        <ul className="sb-list">
          <li>
            <button className="sb-item sb-item--ai">
              <span className="sb-item-strand sb-item-strand--gold" />
              <span className="sb-item-name">v2.41 release train</span>
              <span className="sb-item-time">5m</span>
            </button>
          </li>
          <li>
            <button className="sb-item sb-item--ai">
              <span className="sb-item-strand sb-item-strand--copper" />
              <span className="sb-item-name">Q2 retro · highlights</span>
              <span className="sb-item-time">2d</span>
            </button>
          </li>
        </ul>
      </div>

      <div className="sb-spacer" />

      {/* User footer */}
      <footer className="sb-foot">
        <div className="sb-foot-user">
          <Avatar user={me} size={28} ring="online" />
          <div className="sb-foot-meta">
            <div className="sb-foot-name">{me.name}</div>
            <div className="sb-foot-status">
              <span className="sb-foot-pulse" />
              {me.status}
            </div>
          </div>
        </div>
        <div className="sb-foot-actions">
          <button className="sb-icon-btn" title="Notifications">{I.bell}</button>
          <button className="sb-icon-btn" title="Set status">{I.edit}</button>
          <button className="sb-icon-btn" title="Theme" onClick={() => setDark(!dark)}>
            {dark ? I.sun : I.moon}
          </button>
        </div>
      </footer>
    </aside>
  );
}

window.Sidebar = Sidebar;
