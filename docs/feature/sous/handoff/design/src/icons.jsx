// Icon glyphs + weave-motif primitives for Tenun.
// All icons are stroke-based, currentColor, 16px default. Weave glyphs render the
// warp/weft pattern at different intensities.

const Icon = ({ d, size = 16, stroke = 1.6, fill = 'none' }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill={fill} stroke="currentColor"
       strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round">
    {typeof d === 'string' ? <path d={d} /> : d}
  </svg>
);

const I = {
  search:    <Icon d="M10.5 18a7.5 7.5 0 1 1 0-15 7.5 7.5 0 0 1 0 15Zm10.5 3-4.35-4.35" />,
  plus:      <Icon d="M12 5v14M5 12h14" />,
  hash:      <Icon d="M5 9h14M5 15h14M10 4 8 20M16 4l-2 16" />,
  bell:      <Icon d="M6 8a6 6 0 1 1 12 0c0 7 3 8 3 8H3s3-1 3-8M10 21a2 2 0 0 0 4 0" />,
  edit:      <Icon d="M12 20h9M16.5 3.5a2.12 2.12 0 1 1 3 3L7 19l-4 1 1-4Z" />,
  sun:       <Icon d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41" stroke={1.7} fill="none" />,
  moon:      <Icon d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79Z" />,
  chevDown:  <Icon d="m6 9 6 6 6-6" />,
  chevRight: <Icon d="m9 18 6-6-6-6" />,
  chevLeft:  <Icon d="m15 18-6-6 6-6" />,
  x:         <Icon d="M6 6l12 12M6 18 18 6" />,
  reply:     <Icon d="M9 17l-5-5 5-5M4 12h12a4 4 0 0 1 4 4v3" />,
  smile:     <Icon d="M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18ZM8 14s1.5 2 4 2 4-2 4-2M9 9h.01M15 9h.01" />,
  more:      <Icon d="M5 12h.01M12 12h.01M19 12h.01" stroke={2.4} />,
  bookmark:  <Icon d="M19 21l-7-5-7 5V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2Z" />,
  send:      <Icon d="m22 2-11 11M22 2l-7 20-4-9-9-4Z" />,
  attach:    <Icon d="m21.44 11.05-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48" />,
  mic:       <Icon d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3ZM19 10v2a7 7 0 0 1-14 0v-2M12 19v4M8 23h8" />,
  slash:     <Icon d="M16 4 8 20" />,
  at:        <Icon d="M12 2a10 10 0 1 0 10 10v-1a3 3 0 0 0-6 0v1a4 4 0 1 1-4-4" />,
  bold:      <Icon d="M7 5h6a4 4 0 0 1 0 8H7Zm0 8h7a4 4 0 0 1 0 8H7Z" />,
  italic:    <Icon d="M19 4h-9M14 20H5M15 4 9 20" />,
  code:      <Icon d="m16 18 6-6-6-6M8 6l-6 6 6 6M14 4l-4 16" />,
  link:      <Icon d="M10 13a5 5 0 0 0 7.07 0l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.72M14 11a5 5 0 0 0-7.07 0l-3 3a5 5 0 0 0 7.07 7.07l1.72-1.72" />,
  list:      <Icon d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01" stroke={2} />,
  quote:     <Icon d="M3 21V11a4 4 0 0 1 4-4M13 21V11a4 4 0 0 1 4-4" />,
  spark:     <Icon d={<g><path d="M12 3v4M12 17v4M3 12h4M17 12h4M5.6 5.6l2.8 2.8M15.6 15.6l2.8 2.8M5.6 18.4l2.8-2.8M15.6 8.4l2.8-2.8"/></g>} />,
  jump:      <Icon d="M5 12h14M13 6l6 6-6 6" />,
  pin:       <Icon d="M12 17v5M9 3h6l1 5-2 2a4 4 0 0 0 4 4H6a4 4 0 0 0 4-4L8 8Z" />,
  thread:    <Icon d="M4 4v8a4 4 0 0 0 4 4h12M20 16l-4-4M20 16l-4 4" />,
  github:    <Icon d="M9 19c-5 1.5-5-2.5-7-3m14 6v-3.87a3.37 3.37 0 0 0-.94-2.61c3.14-.35 6.44-1.54 6.44-7A5.44 5.44 0 0 0 20 6.77 5.07 5.07 0 0 0 19.91 3S18.73 2.65 16 4.55a13.38 13.38 0 0 0-7 0C6.27 2.65 5.09 3 5.09 3A5.07 5.07 0 0 0 5 6.77a5.44 5.44 0 0 0-1.5 3.78c0 5.42 3.3 6.61 6.44 7A3.37 3.37 0 0 0 9 20.13V24" />,
  loom:      <Icon d={<g><path d="M3 5h18M3 12h18M3 19h18"/><path d="M7 3v18M12 3v18M17 3v18"/></g>} stroke={1.4} />,
};

// Weave glyph for the Tenun mark — three warp threads crossed by weft.
function TenunMark({ size = 22, color = 'var(--accent)' }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" aria-hidden="true">
      {/* warp (vertical) */}
      <path d="M6 2 V22" stroke={color} strokeWidth="1.8" strokeLinecap="round" opacity="0.9" />
      <path d="M12 2 V22" stroke={color} strokeWidth="1.8" strokeLinecap="round" opacity="0.55" />
      <path d="M18 2 V22" stroke={color} strokeWidth="1.8" strokeLinecap="round" opacity="0.9" />
      {/* weft (horizontal — over/under pattern via dashes) */}
      <path d="M2 7 H22" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"
            strokeDasharray="3 5" opacity="0.85" />
      <path d="M2 12 H22" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"
            strokeDasharray="3 5" strokeDashoffset="4" opacity="0.85" />
      <path d="M2 17 H22" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"
            strokeDasharray="3 5" opacity="0.85" />
    </svg>
  );
}

// Warp bars showing channel activity. 0..1 → 3 bars filled/empty.
function WarpActivity({ value = 0.5 }) {
  const bars = [0, 1, 2];
  const heights = [6, 9, 12];
  const filled = (v, i) => v > (i * 0.33);
  return (
    <svg width="10" height="14" viewBox="0 0 10 14" aria-hidden="true">
      {bars.map((i) => (
        <rect key={i} x={i * 3.5} y={14 - heights[i]} width="1.5" height={heights[i]} rx="0.75"
              fill="currentColor" opacity={filled(value, i) ? 0.9 : 0.18} />
      ))}
    </svg>
  );
}

// Avatar with woven status ring (online state encoded as completion).
function Avatar({ user, size = 28, ring }) {
  const fontSize = Math.round(size * 0.42);
  return (
    <div className="avatar" style={{ width: size, height: size, fontSize, background: user.color }}>
      <span>{user.initial}</span>
      {ring && <span className={`avatar-ring avatar-ring--${ring}`} aria-hidden="true" />}
    </div>
  );
}

// Loom loader — animated warp/weft instead of a spinner.
function LoomLoader({ size = 18 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" className="loom-loader" aria-label="loading">
      <g stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" fill="none">
        <path d="M4 4 V20" opacity="0.7" />
        <path d="M9 4 V20" opacity="0.5" />
        <path d="M14 4 V20" opacity="0.5" />
        <path d="M19 4 V20" opacity="0.7" />
        <path className="weft" d="M2 8 H22" strokeDasharray="4 6">
          <animate attributeName="stroke-dashoffset" from="0" to="-20" dur="1.6s" repeatCount="indefinite" />
        </path>
        <path className="weft" d="M2 12 H22" strokeDasharray="4 6" strokeDashoffset="3">
          <animate attributeName="stroke-dashoffset" from="3" to="-17" dur="1.6s" repeatCount="indefinite" />
        </path>
        <path className="weft" d="M2 16 H22" strokeDasharray="4 6">
          <animate attributeName="stroke-dashoffset" from="0" to="-20" dur="1.6s" repeatCount="indefinite" />
        </path>
      </g>
    </svg>
  );
}

Object.assign(window, { I, TenunMark, WarpActivity, Avatar, LoomLoader });
