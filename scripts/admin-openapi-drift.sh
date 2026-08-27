#!/bin/sh
# Fail when /api/v1 routes in admin.rs drift from docs/openapi/admin-v1.yaml.
set -eu

die() {
  printf 'admin-openapi-drift: %s\n' "$*" >&2
  exit 1
}

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
admin_rs=$repo_root/blaktail-coord/src/admin.rs
openapi=$repo_root/docs/openapi/admin-v1.yaml
command -v python3 >/dev/null 2>&1 || die "python3 is required"
[ -f "$admin_rs" ] || die "missing $admin_rs"
[ -f "$openapi" ] || die "missing $openapi"

python3 - "$admin_rs" "$openapi" <<'PY'
import re
import sys

admin_rs, openapi = sys.argv[1], sys.argv[2]


def normalize(path: str) -> str:
    return re.sub(r":([A-Za-z0-9_]+)", r"{\1}", path)


def rust_ops(source: str) -> set[tuple[str, str]]:
    fn = source.split("pub(crate) fn api_routes()", 1)
    if len(fn) != 2:
        raise SystemExit("admin.rs is missing api_routes()")
    body = fn[1].split("fn require_scope", 1)[0]
    ops: set[tuple[str, str]] = set()
    for match in re.finditer(r'\.route\(\s*"([^"]+)"\s*,', body):
        path = match.group(1)
        rest = body[match.end() :]
        depth = 1
        end = 0
        while end < len(rest) and depth:
            if rest[end] == "(":
                depth += 1
            elif rest[end] == ")":
                depth -= 1
            end += 1
        methods = re.findall(r"\b(get|post|put|patch|delete)\s*\(", rest[:end])
        if not methods:
            raise SystemExit(f"no methods parsed for {path}")
        for method in methods:
            ops.add((method.upper(), normalize(path)))
    if not ops:
        raise SystemExit("parsed zero Rust /api/v1 operations")
    return ops


def openapi_ops(source: str) -> set[tuple[str, str]]:
    ops: set[tuple[str, str]] = set()
    current = None
    for raw in source.splitlines():
        line = raw.rstrip()
        path_match = re.match(r"^  (/api/v1\S+):$", line)
        if path_match:
            current = path_match.group(1)
            continue
        method_match = re.match(r"^    (get|post|put|patch|delete):$", line)
        if method_match and current:
            ops.add((method_match.group(1).upper(), current))
    return ops


with open(admin_rs, encoding="utf-8") as handle:
    rust = rust_ops(handle.read())
with open(openapi, encoding="utf-8") as handle:
    spec = openapi_ops(handle.read())

missing_spec = sorted(rust - spec)
missing_rust = sorted(spec - rust)
if missing_spec or missing_rust:
    for method, path in missing_spec:
        print(f"documented missing: {method} {path}", file=sys.stderr)
    for method, path in missing_rust:
        print(f"implemented missing: {method} {path}", file=sys.stderr)
    raise SystemExit(1)
print(f"admin OpenAPI matches {len(rust)} /api/v1 operations")
PY
