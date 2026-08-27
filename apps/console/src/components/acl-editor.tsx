"use client";

import { useMemo, useState, useTransition } from "react";
import { saveAclAction } from "@/app/actions";
import {
  ACL_ROLES,
  ACL_TAGS,
  emptyRule,
  expandGroupMembers,
  memberLabel,
  parseAclPolicy,
  personLabel,
  serializeAclPolicy,
  validGroupName,
  type AclPerson,
  type AclPolicyDraft,
  type AclRuleDraft,
} from "@/lib/acl";
import { canMutateTailnet, roleLabel, type OrgRole } from "@/lib/roles";

function toggleValue<T extends string>(values: T[], value: T): T[] {
  return values.includes(value)
    ? values.filter((item) => item !== value)
    : [...values, value];
}

function SelectorSet<T extends string>({
  legend,
  values,
  options,
  disabled,
  labelFor,
  onChange,
}: {
  legend: string;
  values: T[];
  options: T[];
  disabled: boolean;
  labelFor: (value: T) => string;
  onChange: (next: T[]) => void;
}) {
  return (
    <fieldset className="acl-selector" disabled={disabled}>
      <legend>{legend}</legend>
      <div className="acl-options">
        {options.map((option) => (
          <label key={option}>
            <input
              type="checkbox"
              checked={values.includes(option)}
              onChange={() => onChange(toggleValue(values, option))}
            />
            {labelFor(option)}
          </label>
        ))}
        {options.length === 0 ? (
          <p className="muted">Add a group first if you want to name people here.</p>
        ) : null}
      </div>
    </fieldset>
  );
}

export function AclEditor({
  initialAcl,
  role,
  people,
}: {
  initialAcl: string;
  role: OrgRole;
  people: AclPerson[];
}) {
  const canMutate = canMutateTailnet(role);
  const parsedInitial = useMemo(() => {
    try {
      return parseAclPolicy(JSON.parse(initialAcl) as unknown);
    } catch {
      return parseAclPolicy({ rules: [] });
    }
  }, [initialAcl]);
  const [policy, setPolicy] = useState<AclPolicyDraft>(parsedInitial);
  const [groupName, setGroupName] = useState("");
  const [groupMember, setGroupMember] = useState("");
  const [message, setMessage] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const groupNames = policy.groups.map((group) => group.name);

  function updateRule(index: number, next: AclRuleDraft) {
    setPolicy((current) => ({
      ...current,
      rules: current.rules.map((rule, ruleIndex) =>
        ruleIndex === index ? next : rule,
      ),
    }));
  }

  return (
    <div className="acl-layout">
      <section className="acl-section">
        <div>
          <h2>Groups</h2>
          <p className="muted">
            Name a set of people, then use that name in a rule. Members are
            matched to the account that enrolled each device.
          </p>
        </div>
        {policy.groups.length === 0 ? (
          <p className="muted">No groups yet. Create one for a team or site.</p>
        ) : (
          <ul className="acl-group-list">
            {policy.groups.map((group) => (
              <li key={group.name} className="acl-group">
                <div className="acl-group-head">
                  <strong>{group.name}</strong>
                  {canMutate ? (
                    <button
                      type="button"
                      className="secondary"
                      onClick={() =>
                        setPolicy((current) => ({
                          ...current,
                          groups: current.groups.filter(
                            (item) => item.name !== group.name,
                          ),
                          rules: current.rules.map((rule) => ({
                            ...rule,
                            src_groups: rule.src_groups.filter(
                              (name) => name !== group.name,
                            ),
                            dst_groups: rule.dst_groups.filter(
                              (name) => name !== group.name,
                            ),
                          })),
                        }))
                      }
                    >
                      Remove group
                    </button>
                  ) : null}
                </div>
                <div className="acl-members">
                  {group.members
                    .filter((member, index, members) => {
                      const person = people.find(
                        (candidate) =>
                          candidate.userId === member ||
                          candidate.email.toLowerCase() === member.toLowerCase(),
                      );
                      if (!person) return true;
                      return (
                        members.findIndex(
                          (item) =>
                            item === person.userId ||
                            item.toLowerCase() === person.email.toLowerCase(),
                        ) === index
                      );
                    })
                    .map((member) => (
                      <span key={member} className="badge">
                        {memberLabel(member, people)}
                        {canMutate ? (
                          <button
                            type="button"
                            className="chip-remove"
                            aria-label={`Remove ${memberLabel(member, people)} from ${group.name}`}
                            onClick={() =>
                              setPolicy((current) => ({
                                ...current,
                                groups: current.groups.map((item) =>
                                  item.name === group.name
                                    ? {
                                        ...item,
                                        members: item.members.filter(
                                          (value) => {
                                            const person = people.find(
                                              (candidate) =>
                                                candidate.userId === member ||
                                                candidate.email.toLowerCase() ===
                                                  member.toLowerCase(),
                                            );
                                            if (!person) return value !== member;
                                            return (
                                              value !== person.userId &&
                                              value.toLowerCase() !==
                                                person.email.toLowerCase()
                                            );
                                          },
                                        ),
                                      }
                                    : item,
                                ),
                              }))
                            }
                          >
                            Remove
                          </button>
                        ) : null}
                      </span>
                    ))}
                </div>
                {canMutate ? (
                  <label>
                    Add a person
                    <select
                      value=""
                      onChange={(event) => {
                        const value = event.target.value;
                        if (!value) return;
                        setPolicy((current) => ({
                          ...current,
                          groups: current.groups.map((item) =>
                            item.name === group.name
                              ? {
                                  ...item,
                                  members: expandGroupMembers(
                                    [...item.members, value],
                                    people,
                                  ),
                                }
                              : item,
                          ),
                        }));
                      }}
                    >
                      <option value="">Choose someone in this organisation</option>
                      {people.map((person) => (
                        <option key={person.userId} value={person.email}>
                          {personLabel(person)}
                        </option>
                      ))}
                    </select>
                  </label>
                ) : null}
              </li>
            ))}
          </ul>
        )}
        {canMutate ? (
          <form
            className="acl-add-group"
            onSubmit={(event) => {
              event.preventDefault();
              const name = groupName.trim().toLowerCase();
              const member = groupMember.trim();
              if (!validGroupName(name)) {
                setMessage(
                  "Group names use lowercase letters, then letters, digits, or hyphens.",
                );
                return;
              }
              if (policy.groups.some((group) => group.name === name)) {
                setMessage("That group name is already in use.");
                return;
              }
              if (!member) {
                setMessage("Add at least one person when you create a group.");
                return;
              }
              setMessage(null);
              setPolicy((current) => ({
                ...current,
                groups: [
                  ...current.groups,
                  { name, members: expandGroupMembers([member], people) },
                ],
              }));
              setGroupName("");
              setGroupMember("");
            }}
          >
            <label>
              New group name
              <input
                name="group-name"
                value={groupName}
                onChange={(event) => setGroupName(event.target.value)}
                placeholder="rangers"
                autoComplete="off"
              />
            </label>
            <label>
              First person
              <select
                name="group-member"
                value={groupMember}
                onChange={(event) => setGroupMember(event.target.value)}
              >
                <option value="">Choose someone</option>
                {people.map((person) => (
                  <option key={person.userId} value={person.email}>
                    {personLabel(person)}
                  </option>
                ))}
              </select>
            </label>
            <button type="submit" className="secondary" data-testid="acl-add-group">
              Add group
            </button>
          </form>
        ) : null}
      </section>

      <section className="acl-section">
        <div>
          <h2>Rules</h2>
          <p className="muted">
            Explicit deny wins. A blank source or destination matches everyone
            on that side. Tagged devices still default to the same tag unless a
            rule says otherwise.
          </p>
        </div>
        {policy.rules.length === 0 ? (
          <p className="muted">No extra rules. Same-tag devices can already reach each other.</p>
        ) : (
          <ol className="acl-rule-list">
            {policy.rules.map((rule, index) => (
              <li key={index} className="acl-rule">
                <div className="acl-rule-head">
                  <label>
                    Action
                    <select
                      value={rule.action}
                      disabled={!canMutate}
                      onChange={(event) =>
                        updateRule(index, {
                          ...rule,
                          action: event.target.value === "deny" ? "deny" : "allow",
                        })
                      }
                    >
                      <option value="allow">Allow</option>
                      <option value="deny">Deny</option>
                    </select>
                  </label>
                  {canMutate ? (
                    <button
                      type="button"
                      className="secondary"
                      onClick={() =>
                        setPolicy((current) => ({
                          ...current,
                          rules: current.rules.filter(
                            (_, ruleIndex) => ruleIndex !== index,
                          ),
                        }))
                      }
                    >
                      Remove rule
                    </button>
                  ) : null}
                </div>
                <div className="acl-rule-grid">
                  <SelectorSet
                    legend="From roles"
                    values={rule.src_roles}
                    options={ACL_ROLES}
                    disabled={!canMutate}
                    labelFor={roleLabel}
                    onChange={(src_roles) => updateRule(index, { ...rule, src_roles })}
                  />
                  <SelectorSet
                    legend="From tags"
                    values={rule.src_tags}
                    options={ACL_TAGS}
                    disabled={!canMutate}
                    labelFor={(tag) => tag}
                    onChange={(src_tags) => updateRule(index, { ...rule, src_tags })}
                  />
                  <SelectorSet
                    legend="From groups"
                    values={rule.src_groups}
                    options={groupNames}
                    disabled={!canMutate}
                    labelFor={(name) => name}
                    onChange={(src_groups) =>
                      updateRule(index, { ...rule, src_groups })
                    }
                  />
                  <SelectorSet
                    legend="To roles"
                    values={rule.dst_roles}
                    options={ACL_ROLES}
                    disabled={!canMutate}
                    labelFor={roleLabel}
                    onChange={(dst_roles) => updateRule(index, { ...rule, dst_roles })}
                  />
                  <SelectorSet
                    legend="To tags"
                    values={rule.dst_tags}
                    options={ACL_TAGS}
                    disabled={!canMutate}
                    labelFor={(tag) => tag}
                    onChange={(dst_tags) => updateRule(index, { ...rule, dst_tags })}
                  />
                  <SelectorSet
                    legend="To groups"
                    values={rule.dst_groups}
                    options={groupNames}
                    disabled={!canMutate}
                    labelFor={(name) => name}
                    onChange={(dst_groups) =>
                      updateRule(index, { ...rule, dst_groups })
                    }
                  />
                </div>
              </li>
            ))}
          </ol>
        )}
        {canMutate ? (
          <button
            type="button"
            className="secondary"
            data-testid="acl-add-rule"
            onClick={() =>
              setPolicy((current) => ({
                ...current,
                rules: [...current.rules, emptyRule()],
              }))
            }
          >
            Add rule
          </button>
        ) : (
          <p className="muted">Members can read access policy but cannot change it.</p>
        )}
      </section>

      {canMutate ? (
        <div className="actions">
          <button
            type="button"
            data-testid="acl-save"
            disabled={pending}
            onClick={() => {
              const formData = new FormData();
              formData.set(
                "aclJson",
                JSON.stringify(serializeAclPolicy(policy), null, 2),
              );
              setMessage(null);
              startTransition(async () => {
                const result = await saveAclAction(formData);
                setMessage(
                  result.ok ? "Access policy saved on the coordinator." : result.error,
                );
              });
            }}
          >
            {pending ? "Saving…" : "Save access policy"}
          </button>
        </div>
      ) : null}

      {message ? (
        <p
          className={
            message.startsWith("Access policy saved") ? "muted" : "error"
          }
          role={message.startsWith("Access policy saved") ? "status" : "alert"}
        >
          {message}
        </p>
      ) : null}

      <details className="acl-advanced">
        <summary>Advanced JSON</summary>
        <pre className="mono">{JSON.stringify(serializeAclPolicy(policy), null, 2)}</pre>
      </details>
    </div>
  );
}
