import { test } from "node:test";
import assert from "node:assert/strict";
import {
  expandGroupMembers,
  parseAclPolicy,
  serializeAclPolicy,
  validGroupName,
} from "../src/lib/acl.ts";

test("ACL drafts keep groups and compact empty selectors", () => {
  const policy = parseAclPolicy({
    groups: { rangers: ["alice@example.test", "alice-user"] },
    rules: [
      {
        action: "allow",
        src_groups: ["rangers"],
        dst_tags: ["store"],
        src_roles: [],
      },
    ],
  });
  assert.deepEqual(policy.groups, [
    { name: "rangers", members: ["alice@example.test", "alice-user"] },
  ]);
  assert.equal(validGroupName("rangers"), true);
  assert.equal(validGroupName("Rangers"), false);
  const people = [
    {
      userId: "alice-user",
      email: "alice@example.test",
      name: "Alice",
    },
  ];
  assert.deepEqual(
    expandGroupMembers(["alice@example.test"], people).sort(),
    ["alice-user", "alice@example.test"].sort(),
  );
  assert.deepEqual(serializeAclPolicy(policy), {
    version: 1,
    groups: { rangers: ["alice@example.test", "alice-user"] },
    rules: [{ action: "allow", src_groups: ["rangers"], dst_tags: ["store"] }],
  });
});

test("ACL drafts keep hosts, ports, and protocols across a round trip", () => {
  const policy = parseAclPolicy({
    hosts: { wiki: "10.0.0.10" },
    rules: [
      {
        action: "allow",
        src_groups: ["rangers"],
        dst_hosts: ["wiki"],
        dst_ports: ["443"],
        protocols: ["tcp"],
      },
    ],
  });
  assert.deepEqual(policy.hosts, [{ name: "wiki", target: "10.0.0.10" }]);
  assert.deepEqual(serializeAclPolicy(policy), {
    version: 1,
    groups: {},
    hosts: { wiki: "10.0.0.10" },
    rules: [
      {
        action: "allow",
        src_groups: ["rangers"],
        dst_hosts: ["wiki"],
        dst_ports: ["443"],
        protocols: ["tcp"],
      },
    ],
  });
});

test("ACL drafts keep policy tests and tag owners across a round trip", () => {
  const policy = parseAclPolicy({
    version: 1,
    tag_owners: { office: ["owner-1"] },
    tests: [{ name: "office isolated", src_tags: ["office"], dst_tags: ["store"], allow: false }],
    rules: [],
  });
  assert.equal(policy.version, 1);
  assert.deepEqual(policy.tag_owners, [{ tag: "office", owners: ["owner-1"] }]);
  assert.equal(policy.tests.length, 1);
  assert.deepEqual(serializeAclPolicy(policy), {
    version: 1,
    groups: {},
    tag_owners: { office: ["owner-1"] },
    tests: [{ name: "office isolated", src_tags: ["office"], dst_tags: ["store"], allow: false }],
    rules: [],
  });
});
