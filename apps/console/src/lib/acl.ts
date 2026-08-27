import type { OrgRole } from "./roles";

export type AclTag = "office" | "ranger" | "store";

export const ACL_ROLES: OrgRole[] = ["owner", "admin", "member"];
export const ACL_TAGS: AclTag[] = ["office", "ranger", "store"];

export type AclPerson = {
  userId: string;
  email: string;
  name: string;
};

export type AclRuleDraft = {
  action: "allow" | "deny";
  src_roles: OrgRole[];
  src_tags: AclTag[];
  src_groups: string[];
  dst_roles: OrgRole[];
  dst_tags: AclTag[];
  dst_groups: string[];
};

export type AclPolicyDraft = {
  groups: { name: string; members: string[] }[];
  rules: AclRuleDraft[];
};

function asStringArray(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];
}

function asRoleArray(value: unknown): OrgRole[] {
  return asStringArray(value).filter((item): item is OrgRole =>
    ACL_ROLES.includes(item as OrgRole),
  );
}

function asTagArray(value: unknown): AclTag[] {
  return asStringArray(value).filter((item): item is AclTag =>
    ACL_TAGS.includes(item as AclTag),
  );
}

export function emptyRule(): AclRuleDraft {
  return {
    action: "allow",
    src_roles: [],
    src_tags: [],
    src_groups: [],
    dst_roles: [],
    dst_tags: [],
    dst_groups: [],
  };
}

export function parseAclPolicy(value: unknown): AclPolicyDraft {
  const source =
    value && typeof value === "object" ? (value as Record<string, unknown>) : {};
  const groupsValue = source.groups;
  const groups =
    groupsValue && typeof groupsValue === "object" && !Array.isArray(groupsValue)
      ? Object.entries(groupsValue as Record<string, unknown>).map(
          ([name, members]) => ({
            name,
            members: asStringArray(members),
          }),
        )
      : [];
  const rules = Array.isArray(source.rules)
    ? source.rules.map((rule) => {
        const row =
          rule && typeof rule === "object"
            ? (rule as Record<string, unknown>)
            : {};
        return {
          action: row.action === "deny" ? "deny" : "allow",
          src_roles: asRoleArray(row.src_roles),
          src_tags: asTagArray(row.src_tags),
          src_groups: asStringArray(row.src_groups),
          dst_roles: asRoleArray(row.dst_roles),
          dst_tags: asTagArray(row.dst_tags),
          dst_groups: asStringArray(row.dst_groups),
        } satisfies AclRuleDraft;
      })
    : [];
  return { groups, rules };
}

export function validGroupName(name: string): boolean {
  return /^[a-z][a-z0-9-]{0,31}$/u.test(name);
}

export function personLabel(person: AclPerson): string {
  return person.name ? `${person.name} (${person.email})` : person.email;
}

export function memberLabel(member: string, people: AclPerson[]): string {
  const match = people.find(
    (person) =>
      person.userId === member ||
      person.email.toLowerCase() === member.toLowerCase(),
  );
  return match ? personLabel(match) : member;
}

export function expandGroupMembers(
  selected: string[],
  people: AclPerson[],
): string[] {
  const members = new Set<string>();
  for (const value of selected) {
    const trimmed = value.trim();
    if (!trimmed) continue;
    members.add(trimmed);
    const person = people.find(
      (candidate) =>
        candidate.userId === trimmed ||
        candidate.email.toLowerCase() === trimmed.toLowerCase(),
    );
    if (!person) continue;
    members.add(person.email);
    members.add(person.userId);
  }
  return [...members];
}

function compact<T>(key: string, values: T[]): Record<string, T[]> {
  return values.length > 0 ? { [key]: values } : {};
}

export function serializeAclPolicy(policy: AclPolicyDraft): Record<string, unknown> {
  const groups = Object.fromEntries(
    policy.groups
      .map((group) => [
        group.name.trim(),
        [...new Set(group.members.map((member) => member.trim()).filter(Boolean))],
      ])
      .filter(([name, members]) => name && (members as string[]).length > 0),
  );
  return {
    groups,
    rules: policy.rules.map((rule) => ({
      action: rule.action,
      ...compact("src_roles", rule.src_roles),
      ...compact("src_tags", rule.src_tags),
      ...compact("src_groups", rule.src_groups),
      ...compact("dst_roles", rule.dst_roles),
      ...compact("dst_tags", rule.dst_tags),
      ...compact("dst_groups", rule.dst_groups),
    })),
  };
}
