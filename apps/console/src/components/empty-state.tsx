import type { ReactNode } from "react";
import { PathMotif } from "./path-motif";

export function EmptyState({
  title,
  body,
  action,
}: {
  title: string;
  body: string;
  action?: ReactNode;
}) {
  return (
    <div className="empty-state">
      <PathMotif />
      <h2>{title}</h2>
      <p className="muted">{body}</p>
      {action}
    </div>
  );
}
