// The handful of icons the pages use, drawn inline so nothing loads from elsewhere.

const base = { width: 15, height: 15, viewBox: "0 0 16 16", fill: "none", stroke: "currentColor", "stroke-width": 1.5, "stroke-linecap": "round", "stroke-linejoin": "round" } as const;

export const Play = () => (
  <svg {...base}>
    <circle cx="8" cy="8" r="6.5" />
    <path d="M6.5 5.5v5l4-2.5z" fill="currentColor" stroke="none" />
  </svg>
);

export const Stop = () => (
  <svg {...base}>
    <circle cx="8" cy="8" r="6.5" />
    <rect x="5.75" y="5.75" width="4.5" height="4.5" fill="currentColor" stroke="none" />
  </svg>
);

export const Copy = () => (
  <svg {...base}>
    <rect x="5" y="5" width="8.5" height="8.5" rx="1.5" />
    <path d="M3 10.5V3.5A1 1 0 0 1 4 2.5h7" />
  </svg>
);

export const Pencil = () => (
  <svg {...base}>
    <path d="M10.5 2.5l3 3L6 13H3v-3z" />
  </svg>
);

export const Retry = () => (
  <svg {...base}>
    <path d="M13 8a5 5 0 1 1-1.5-3.6" />
    <path d="M13 2.5V5h-2.5" />
  </svg>
);

export const Trash = () => (
  <svg {...base}>
    <path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5" />
  </svg>
);

export const Plus = () => (
  <svg {...base}>
    <path d="M8 3.5v9M3.5 8h9" />
  </svg>
);

export const More = () => (
  <svg {...base}>
    <circle cx="3.5" cy="8" r="0.9" fill="currentColor" />
    <circle cx="8" cy="8" r="0.9" fill="currentColor" />
    <circle cx="12.5" cy="8" r="0.9" fill="currentColor" />
  </svg>
);

export const Mic = ({ size = 15, color = "currentColor" }: { size?: number; color?: string }) => (
  <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke={color} stroke-width={1.6} stroke-linecap="round">
    <rect x="5.75" y="1.75" width="4.5" height="8" rx="2.25" fill={color} stroke="none" />
    <path d="M3.5 7.5a4.5 4.5 0 0 0 9 0M8 12v2.5M5.5 14.5h5" />
  </svg>
);

export const Close = ({ color = "currentColor" }: { color?: string }) => (
  <svg width="10" height="10" viewBox="0 0 10 10" stroke={color} stroke-width={1.6} stroke-linecap="round">
    <path d="M2 2l6 6M8 2L2 8" />
  </svg>
);
