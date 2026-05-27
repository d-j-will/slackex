// Message list + individual message rendering for the active channel.

function MessageBody({ items, serifAI }) {
  return (
    <div className="msg-body">
      {items.map((it, i) => {
        if (it.type === 'text') {
          return <p key={i} className="msg-p">{renderInline(it.value)}</p>;
        }
        if (it.type === 'ai-context') {
          return (
            <div key={i} className={`msg-ai-ctx ${serifAI ? 'is-serif' : ''}`}>
              <span className="msg-ai-spark" />
              {it.value}
            </div>
          );
        }
        if (it.type === 'callout') {
          return (
            <div key={i} className={`msg-callout msg-callout--${it.tone}`}>
              <span className="msg-callout-icon">{it.icon}</span>
              <span>{it.text}</span>
            </div>
          );
        }
        if (it.type === 'code') {
          return (
            <pre key={i} className="msg-code">
              <div className="msg-code-hd">
                <span className="msg-code-lang">{it.lang}</span>
                <button className="msg-code-copy">copy</button>
              </div>
              <code>{it.value}</code>
            </pre>
          );
        }
        if (it.type === 'unfurl') {
          return (
            <div key={i} className="msg-unfurl">
              <div className="msg-unfurl-strand" />
              <div className="msg-unfurl-body">
                <div className="msg-unfurl-site">{I.github}<span>{it.site}</span></div>
                <div className="msg-unfurl-title">{it.title}</div>
                <div className="msg-unfurl-sub">{it.subtitle}</div>
                {it.meta && (
                  <div className="msg-unfurl-meta">
                    {it.meta.map((m, j) => <span key={j}>{m}</span>)}
                  </div>
                )}
              </div>
            </div>
          );
        }
        if (it.type === 'pr') return <PRCard key={i} id={it.pr} />;
        if (it.type === 'decision') return <DecisionCard key={i} data={it} />;
        if (it.type === 'customer-row') return <CustomerVoice key={i} ids={it.customers} />;
        if (it.type === 'oncall-handoff') return (
          <OncallHandoff key={i} from={it.from} to={it.to} until={it.until} notes={it.notes} />
        );
        if (it.type === 'markdown-demo') return <MarkdownDemo key={i} />;
        if (it.type === 'metrics') return <MetricsBlock key={i} />;
        return null;
      })}
    </div>
  );
}

function ReactionStrip({ reactions, onReact }) {
  if (!reactions || !reactions.length) return null;
  return (
    <div className="rxn-strip">
      {reactions.map((r, i) => (
        <button key={i} className={`rxn ${r.mine ? 'is-mine' : ''}`}>
          <span className="rxn-em">{r.emoji}</span>
          <span className="rxn-n">{r.count}</span>
        </button>
      ))}
      <button className="rxn rxn-add" title="Add reaction">{I.smile}</button>
    </div>
  );
}

function ThreadStub({ count, users, time, onOpen }) {
  const { USERS } = window.TENUN;
  return (
    <button className="thread-stub" onClick={onOpen}>
      <span className="thread-stub-strands">
        {users.slice(0, 3).map((u, i) => (
          <span key={u} className="thread-stub-av" style={{ background: USERS[u].color, left: i * 12 }}>
            {USERS[u].initial}
          </span>
        ))}
      </span>
      <span className="thread-stub-count">{count} {count === 1 ? 'reply' : 'replies'}</span>
      <span className="thread-stub-time">last reply {time}</span>
      <span className="thread-stub-cta">View thread {I.chevRight}</span>
    </button>
  );
}

function MessageRow({ msg, prev, serifAI, onOpenThread }) {
  const { USERS } = window.TENUN;
  // Day / unread dividers
  if (msg.type === 'day') {
    return (
      <div className="divider divider--day">
        <span className="divider-line" />
        <span className="divider-label">{msg.label}</span>
        <span className="divider-line" />
      </div>
    );
  }
  if (msg.type === 'unread') {
    return (
      <div className="divider divider--unread">
        <span className="divider-line divider-line--unread" />
        <span className="divider-label divider-label--unread">{msg.label}</span>
        <span className="divider-line divider-line--unread" />
      </div>
    );
  }

  const u = USERS[msg.user];
  // Compact follow-up: same user, no special body type, within 5 minutes of prev.
  const followUp = prev && prev.user === msg.user && !msg.isBot && !prev.isBot;

  return (
    <article className={`msg ${followUp ? 'msg--follow' : ''} ${msg.isBot ? 'msg--bot' : ''}`}>
      <div className="msg-gutter">
        {followUp ? (
          <span className="msg-time-hover">{msg.time}</span>
        ) : (
          <Avatar user={u} size={36} />
        )}
      </div>
      <div className="msg-main">
        {!followUp && (
          <header className="msg-hd">
            <span className="msg-name">{u.name}</span>
            {msg.isBot && <span className="msg-bot-tag">AI</span>}
            <span className="msg-time">{msg.time}</span>
          </header>
        )}
        <MessageBody items={msg.body} serifAI={serifAI} />
        <ReactionStrip reactions={msg.reactions} />
        {msg.threadCount && (
          <ThreadStub
            count={msg.threadCount}
            users={msg.threadUsers}
            time={msg.threadLastTime}
            onOpen={() => onOpenThread(msg.id)}
          />
        )}
      </div>
      <div className="msg-actions">
        <button className="msg-action" title="React">{I.smile}</button>
        <button className="msg-action" title="Reply in thread" onClick={() => onOpenThread(msg.id)}>{I.thread}</button>
        <button className="msg-action" title="Save">{I.bookmark}</button>
        <button className="msg-action msg-action--ai" title="Ask AI">
          <span className="msg-action-spark" />
        </button>
        <button className="msg-action" title="More">{I.more}</button>
      </div>
    </article>
  );
}

function MessageList({ messages, serifAI, onOpenThread }) {
  return (
    <div className="msg-list">
      {messages.map((m, i) => (
        <MessageRow key={m.id} msg={m} prev={messages[i - 1]} serifAI={serifAI} onOpenThread={onOpenThread} />
      ))}
    </div>
  );
}

window.MessageList = MessageList;
