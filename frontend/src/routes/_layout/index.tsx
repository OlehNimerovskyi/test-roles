import { createFileRoute } from "@tanstack/react-router"

import { Badge } from "@/components/ui/badge"
import useAuth from "@/hooks/useAuth"
import { ROLE_LABELS } from "@/lib/roles"

export const Route = createFileRoute("/_layout/")({
  component: Dashboard,
  head: () => ({
    meta: [
      {
        title: "Dashboard - FastAPI Template",
      },
    ],
  }),
})

function Dashboard() {
  const { user: currentUser } = useAuth()

  return (
    <div>
      <div>
        <h1 className="text-2xl truncate max-w-sm">
          Hi, {currentUser?.full_name || currentUser?.email} 👋
        </h1>
        <p className="text-muted-foreground">
          Welcome back, nice to see you again!!!
        </p>
        {currentUser?.role && (
          <Badge variant="secondary" className="mt-2">
            {ROLE_LABELS[currentUser.role]}
          </Badge>
        )}
      </div>
    </div>
  )
}
