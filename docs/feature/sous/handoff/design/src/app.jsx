// Top-level Tenun app.
// Composes Sidebar + main Channel pane + Thread rail + Summarize overlay.
// Owns global state: active channel, thread root, theme, density, accent, etc.

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "dark": true,
  "density": "regular",
  "accent": "#e8c547",
  "weaveIntensity": "subtle",
  "serifAI": false,
  "showWarpActivity": true,
  "showThreadByDefault": false,
  "viewer": "ceo"
}/*EDITMODE-END*/;

function ChannelHeader({ channel, dense, onSummarize, threadOpen }) {
  return (
    <header className={`ch-head ${dense ? 'ch-head--dense' : ''}`}>
      <div className="ch-head-l">
        <div className="ch-head-title">
          <span className="ch-head-hash">#</span>
          <span className="ch-head-name">{channel.name}</span>
        </div>
        {channel.topic && (
          <div className="ch-head-topic">
            <span className="ch-head-divider" />
            <span>{channel.topic}</span>
          </div>
        )}
      </div>
      <div className="ch-head-r">
        <div className="ch-head-members">
          <div className="ch-head-avs">
            {['mina','jules','keem','efdp','riko'].map((u, i) => (
              <span key={u} className="ch-head-av"
                    style={{ background: window.TENUN.USERS[u].color, zIndex: 10 - i }}>
                {window.TENUN.USERS[u].initial}
              </span>
            ))}
            <span className="ch-head-av ch-head-av--more">+7</span>
          </div>
          <span className="ch-head-count">12</span>
        </div>
        <span className="ch-head-divider" />
        <button className="ch-head-btn ch-head-btn--ai" onClick={onSummarize}>
          <span className="ch-head-spark" />
          <span>Summarize</span>
          <kbd>⌘J</kbd>
        </button>
        <button className="ch-head-btn">
          {I.search}
          <span>Semantic search</span>
        </button>
        <button className="ch-head-icon" title="Pinned">{I.pin}</button>
        <button className="ch-head-icon" title="More">{I.more}</button>
      </div>
    </header>
  );
}

function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const [activeChannel, setActiveChannel] = React.useState('deploys');
  const [threadRoot, setThreadRoot] = React.useState(t.showThreadByDefault ? 'm4' : null);
  const [summarizeOpen, setSummarizeOpen] = React.useState(false);
  const [paletteOpen, setPaletteOpen] = React.useState(false);
  const [tapestryOpen, setTapestryOpen] = React.useState(false);
  const [serviceOpen, setServiceOpen] = React.useState(false);

  // Keyboard: ⌘K palette, ⌘J summarize, ⌘. tapestry, ⌘L in-service
  React.useEffect(() => {
    const onKey = (e) => {
      const cmd = e.metaKey || e.ctrlKey;
      if (cmd && e.key.toLowerCase() === 'k') { e.preventDefault(); setPaletteOpen((p) => !p); }
      if (cmd && e.key.toLowerCase() === 'j') { e.preventDefault(); setSummarizeOpen((p) => !p); }
      if (cmd && e.key.toLowerCase() === 'l') { e.preventDefault(); setServiceOpen((p) => !p); }
      if (cmd && e.key === '.') { e.preventDefault(); setTapestryOpen((p) => !p); }
      if (e.key === 'Escape') { setPaletteOpen(false); setSummarizeOpen(false); setTapestryOpen(false); }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  const channel = window.TENUN.CHANNELS.find((c) => c.id === activeChannel) || window.TENUN.CHANNELS[0];

  // Apply theme + tweak vars
  const rootClass = [
    'app',
    t.dark ? 'theme-dark' : 'theme-light',
    `density-${t.density}`,
    `weave-${t.weaveIntensity}`,
    threadRoot ? 'has-thread' : '',
    summarizeOpen ? 'has-sum' : '',
  ].join(' ');

  const rootStyle = {
    '--accent': t.accent,
    '--accent-soft': t.accent + '55',
    '--accent-wash': t.accent + '14',
  };

  return (
    <div className={rootClass} style={rootStyle}>
      {/* Subtle weave texture overlay — global */}
      <div className="weave-bg" aria-hidden="true" />

      <Sidebar
        activeChannel={activeChannel}
        onPickChannel={setActiveChannel}
        onTogglePalette={() => setPaletteOpen(true)}
        onOpenTapestry={() => setTapestryOpen(true)}
        onOpenService={() => setServiceOpen(true)}
        viewer={window.TENUN.VIEWERS[t.viewer]}
        dark={t.dark}
        setDark={(v) => setTweak('dark', v)}
      />

      <main className="main">
        <ChannelHeader
          channel={channel}
          dense={t.density === 'compact'}
          onSummarize={() => setSummarizeOpen(true)}
          threadOpen={!!threadRoot}
        />
        <div className="main-scroll">
          <OnTheLoomStrip serifAI={t.serifAI} />
          <ChannelIntro channel={channel} />
          <MessageList
            messages={window.TENUN.MESSAGES}
            serifAI={t.serifAI}
            onOpenThread={setThreadRoot}
          />
        </div>
        <Composer channel={channel} dense={t.density === 'compact'} serifAI={t.serifAI} />
      </main>

      {threadRoot && (
        <Thread rootId={threadRoot} onClose={() => setThreadRoot(null)} serifAI={t.serifAI} />
      )}

      <SummarizeOverlay
        open={summarizeOpen}
        onClose={() => setSummarizeOpen(false)}
        serifAI={t.serifAI}
        onJumpTo={(id) => { setSummarizeOpen(false); /* would scroll to id */ }}
      />

      <Tapestry
        open={tapestryOpen}
        onClose={() => setTapestryOpen(false)}
        viewerId={t.viewer}
        setViewer={(v) => setTweak('viewer', v)}
        serifAI={t.serifAI}
      />

      <InService
        open={serviceOpen}
        onClose={() => setServiceOpen(false)}
        viewerId={t.viewer}
        setViewer={(v) => setTweak('viewer', v)}
        serifAI={t.serifAI}
      />

      {paletteOpen && <CommandPalette onClose={() => setPaletteOpen(false)} />}

      <TweaksPanel title="Tweaks">
        <TweakSection label="Theme" />
        <TweakToggle label="Dark mode" value={t.dark} onChange={(v) => setTweak('dark', v)} />
        <TweakRadio label="Density" value={t.density}
                    options={['compact', 'regular', 'comfy']}
                    onChange={(v) => setTweak('density', v)} />
        <TweakColor label="Accent" value={t.accent}
                    options={['#e8c547','#d97757','#3ecf8e','#7c5cff','#ff5b8a','#7fb5ff']}
                    onChange={(v) => setTweak('accent', v)} />

        <TweakSection label="Weave identity" />
        <TweakRadio label="Texture" value={t.weaveIntensity}
                    options={['off', 'subtle', 'pronounced']}
                    onChange={(v) => setTweak('weaveIntensity', v)} />
        <TweakToggle label="Warp activity bars" value={t.showWarpActivity}
                     onChange={(v) => setTweak('showWarpActivity', v)} />

        <TweakSection label="AI" />
        <TweakToggle label="Serif for AI moments" value={t.serifAI}
                     onChange={(v) => setTweak('serifAI', v)} />
        <TweakRadio label="Reading as" value={t.viewer}
                    options={['ceo', 'cto', 'em', 'keem', 'efdp', 'dave', 'mina']}
                    onChange={(v) => setTweak('viewer', v)} />
        <TweakButton label="Open the Pass"
                     onClick={() => setTapestryOpen(true)} />
        <TweakButton label="Open In Service"
                     onClick={() => setServiceOpen(true)} />
        <TweakButton label="Open Summary"
                     onClick={() => setSummarizeOpen(true)} />
        <TweakButton label="Toggle thread"
                     onClick={() => setThreadRoot(threadRoot ? null : 'm4')} />
      </TweaksPanel>
    </div>
  );
}

function ChannelIntro({ channel }) {
  return (
    <div className="ch-intro">
      <div className="ch-intro-mark">
        <TenunMark size={32} />
      </div>
      <h2 className="ch-intro-title">Welcome to <span>#{channel.name}</span></h2>
      <p className="ch-intro-sub">
        This is the very start of the channel. {channel.topic && <>Topic: <em>{channel.topic}</em></>}
      </p>
      <div className="ch-intro-actions">
        <button>{I.edit}<span>Edit topic</span></button>
        <button>{I.plus}<span>Add people</span></button>
        <button>{I.bookmark}<span>Pin a message</span></button>
      </div>
    </div>
  );
}

function CommandPalette({ onClose }) {
  const [q, setQ] = React.useState('');
  const suggestions = [
    { kind: 'semantic', label: 'pgvector backfill status', meta: '#deploys · 2h ago · mina' },
    { kind: 'semantic', label: 'chunked summariser implementation', meta: '#deploys · jules · PR #1842' },
    { kind: 'channel', label: '#tenun-bugs-annoyances', meta: 'Channel · 312 members' },
    { kind: 'people', label: 'Mina Lin', meta: '@mina · Engineering' },
    { kind: 'action', label: 'Summarize this channel', meta: '⌘J' },
    { kind: 'action', label: 'Mark all read', meta: 'Esc, Shift+Esc' },
  ];
  return (
    <div className="palette-overlay" onClick={onClose}>
      <div className="palette" onClick={(e) => e.stopPropagation()}>
        <div className="palette-input">
          <span className="palette-spark" />
          <input autoFocus placeholder="Jump to a channel, person, or ask semantically…"
                 value={q} onChange={(e) => setQ(e.target.value)} />
          <kbd>Esc</kbd>
        </div>
        <div className="palette-hint">
          Try: <em>"that thing mina said about embeddings"</em>
        </div>
        <ul className="palette-list">
          {suggestions.map((s, i) => (
            <li key={i} className={`palette-item palette-item--${s.kind} ${i === 0 ? 'is-sel' : ''}`}>
              <span className={`palette-item-kind palette-item-kind--${s.kind}`}>
                {s.kind === 'semantic' && <span className="palette-spark palette-spark--sm" />}
                {s.kind === 'channel' && '#'}
                {s.kind === 'people' && '@'}
                {s.kind === 'action' && '/'}
              </span>
              <span className="palette-item-label">{s.label}</span>
              <span className="palette-item-meta">{s.meta}</span>
            </li>
          ))}
        </ul>
        <footer className="palette-foot">
          <span>↑↓ navigate</span>
          <span>↵ open</span>
          <span>⌘↵ open in new pane</span>
          <span className="palette-foot-spacer" />
          <span>powered by pgvector + claude</span>
        </footer>
      </div>
    </div>
  );
}

window.App = App;
