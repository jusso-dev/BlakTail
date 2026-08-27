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
    groups: { rangers: ["alice@example.test", "alice-user"] },
    rules: [{ action: "allow", src_groups: ["rangers"], dst_tags: ["store"] }],
  });
});
