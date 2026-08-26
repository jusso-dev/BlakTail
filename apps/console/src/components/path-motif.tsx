export function PathMotif({
  className = "path-motif",
  title,
}: {
  className?: string;
  title?: string;
}) {
  return (
    <svg
      className={className}
      viewBox="0 0 320 120"
      role={title ? "img" : "presentation"}
      aria-hidden={title ? undefined : true}
      aria-label={title}
    >
      {title ? <title>{title}</title> : null}
      <path d="M18 86 C 58 86, 72 34, 118 34 S 168 88, 214 70 S 268 28, 304 40" />
      <path className="quiet" d="M28 54 C 78 18, 132 96, 198 48 S 268 18, 306 62" />
      <path className="gold" d="M46 96 C 96 70, 140 108, 186 86 S 250 96, 292 78" />
      <circle cx="18" cy="86" r="3.2" />
      <circle cx="118" cy="34" r="3.2" />
      <circle cx="214" cy="70" r="3.2" />
      <circle cx="304" cy="40" r="3.2" />
      <circle className="hub" cx="118" cy="34" r="8" />
      <circle className="hub" cx="214" cy="70" r="7" />
    </svg>
  );
}
