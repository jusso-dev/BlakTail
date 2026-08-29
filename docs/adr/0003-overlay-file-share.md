# ADR 0003 — Overlay read-only file shares

- Status: accepted for the first share slice
- Date: 2026-08-29

## Decision

The first file-sharing product is a **read-only HTTP directory with WebDAV
PROPFIND exported by `blaktaild` and bound only to the node's tailnet IPv4
address**.

The coordinator stores share metadata (`label`, absolute path, port, enabled).
It never stores file bytes. Other managed agents discover shares on the
authenticated peer map. Operators and peers browse
`http://<node>.<org>.blaktail:5647/<label>/`. Finder can mount the same URL
with Go → Connect to Server. Write methods stay 403.

## Why this first

| Option | Fit | Cost |
| --- | --- | --- |
| Overlay HTTP directory + read-only WebDAV | Reuses WireGuard, MagicDNS, ACL; Finder can mount | Medium |
| Taildrop-style push | Needs a transfer queue and device picker | High |
| SMB/NFS | OS credentials and a wider attack surface | High |
| #47 private HTTPS Serve | PKI and a service DNS namespace | High, different product |

HTTP over the existing overlay is the smallest thing that gives a shared folder
without inventing a new data-plane or storing files in the coordinator.

## Limits that stay explicit

- Read-only. Writable shares need an auth model that does not exist yet.
- One TCP port per node (default 5647). Several labels share that port.
- Bind is overlay IPv4 only. No LAN and no `0.0.0.0`.
- Path jail: canonicalise under the declared root; reject `..` and symlink escape.
- Peers that current policy already allows to see the node get the share port
  unless a deny rule blocks it.
- macOS still has no packet filter; overlay bind is the control there.
- WireGuard-only peers cannot publish a BlakTail share.

## Follow-on

Write/upload and per-share ACL selectors are later slices. They are not implied
by this ADR. Read-only WebDAV (OPTIONS, PROPFIND Depth 0/1) is part of this
record so Finder can mount the same overlay URL.
