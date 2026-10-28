import type { UserRole } from "@/client"

export const ROLE_LABELS: Record<UserRole, string> = {
  admin: "Admin",
  manager: "Manager",
  member: "Member",
}

export const ROLES = Object.keys(ROLE_LABELS) as UserRole[]
