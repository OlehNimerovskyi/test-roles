import { Briefcase, ChartColumn, Home, Users } from "lucide-react"

import type { Permission } from "@/client"
import { SidebarAppearance } from "@/components/Common/Appearance"
import { Logo } from "@/components/Common/Logo"
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
} from "@/components/ui/sidebar"
import useAuth from "@/hooks/useAuth"
import usePermissions from "@/hooks/usePermissions"
import { type Item, Main } from "./Main"
import { User } from "./User"

type NavItem = Item & { permission?: Permission }

const navItems: NavItem[] = [
  { icon: Home, title: "Dashboard", path: "/" },
  { icon: Briefcase, title: "Items", path: "/items" },
  { icon: Users, title: "Users", path: "/admin", permission: "users:read" },
  {
    icon: ChartColumn,
    title: "Metrics",
    path: "/metrics",
    permission: "metrics:read",
  },
]

export function AppSidebar() {
  const { user: currentUser } = useAuth()
  const { can } = usePermissions()

  const items = navItems.filter(
    (item) => !item.permission || can(item.permission),
  )

  return (
    <Sidebar collapsible="icon">
      <SidebarHeader className="px-4 py-6 group-data-[collapsible=icon]:px-0 group-data-[collapsible=icon]:items-center">
        <Logo variant="responsive" />
      </SidebarHeader>
      <SidebarContent>
        <Main items={items} />
      </SidebarContent>
      <SidebarFooter>
        <SidebarAppearance />
        <User user={currentUser} />
      </SidebarFooter>
    </Sidebar>
  )
}

export default AppSidebar
