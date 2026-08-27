# Security

BlakTail is pre-release software for organisation-operated private networks.
This file is the public reporting contract. It is not an independent audit,
IRAP assessment, or certification.

## Supported versions

Only the latest tagged release and the `main` branch receive security fixes.
Source builds of unreleased commits are unsupported except for operators who
track `main` and apply patches themselves.

## Reporting a vulnerability

Email the maintainer privately at the address on
[https://github.com/jusso-dev](https://github.com/jusso-dev). Do not open a
public GitHub issue for an exploitable coordinator, console, relay, or agent
flaw.

Include:

- affected version or commit SHA
- component (console, coordinator, relay, agent, deployment)
- impact and a minimal reproduction against a disposable environment
- whether you believe the issue is already being exploited

Do not include customer data, live credentials, or exploit payloads against
systems you do not operate.

## Response targets

These are targets, not contractual SLAs:

- acknowledge a private report within 5 business days
- triage severity within 10 business days
- critical/high coordinator or auth flaws: patch or public risk acceptance
  before any production-ready claim
- coordinated disclosure after a fix is available to operators

## Scope

In scope: unauthenticated coordinator/console endpoints, bootstrap and session
auth, browser enrolment, relay framing, agent privilege boundaries, package
and CI supply chain, and deployment defaults in this repository.

Out of scope: live customer deployments you do not operate, denial-of-service
floods, and physical access to an operator's hosts.

## Safe harbour

Good-faith research against your own disposable BlakTail deployment, without
accessing other people's data or disrupting shared infrastructure, is welcome.
Do not test `jusso-dev` production accounts, GitHub Actions, or third-party
IdPs without permission.

## Residual risk

An independent assessment has not been completed. See
[#52](https://github.com/jusso-dev/BlakTail/issues/52),
[docs/threat-model.md](docs/threat-model.md), and the current
[control/evidence matrix](docs/audit-readiness.md).
