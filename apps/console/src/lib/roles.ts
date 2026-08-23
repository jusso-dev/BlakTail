export type OrgRole = "owner" | "admin" | "member";

export function canMutateTailnet(role: OrgRole): boolean {
  return role === "owner" || role === "admin";
}

export function roleLabel(role: OrgRole): string {
  switch (role) {
    case "owner":
      return "Owner";
    case "admin":
      return "Admin";
    case "member":
      return "Member";
  }
}
