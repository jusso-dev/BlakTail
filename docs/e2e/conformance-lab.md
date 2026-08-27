# Local conformance lab

`scripts/conformance/run-lab.sh` mints a unique run ID, runs selected
scenarios, writes a machine-readable manifest, scans evidence for credential
classes, and removes only that run’s temporary directory on success.

```sh
scripts/conformance/run-lab.sh --scenario self-test
scripts/conformance/run-lab.sh --scenario self-test,observability --keep-evidence
scripts/conformance/run-lab.sh --scenario homelab-acl
```

CI runs `scripts/conformance/lab-static-test.sh` on every pull request. That
proves concurrent run IDs stay isolated and that a deliberate failure keeps
diagnostics without deleting another run. The live metrics scrape remains
`scripts/conformance/prove-observability.sh`. Homelab ACL proof stays
operator-triggered because it needs the Docker agents on the LAN stack.

This is the first substrate for #42. Forced-relay, DNS, routes, revoke, and
AWS modes are still selected by the older dedicated scripts until they are
folded in.
