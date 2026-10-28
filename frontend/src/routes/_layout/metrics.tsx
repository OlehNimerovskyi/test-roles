import { useSuspenseQuery } from "@tanstack/react-query"
import { createFileRoute } from "@tanstack/react-router"
import { Suspense } from "react"

import { MetricsService } from "@/client"
import RequirePermission from "@/components/Common/RequirePermission"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { ROLE_LABELS, ROLES } from "@/lib/roles"

function getMetricsQueryOptions() {
  return {
    queryFn: async () => (await MetricsService.readMetrics()).data,
    queryKey: ["metrics"],
  }
}

export const Route = createFileRoute("/_layout/metrics")({
  component: Metrics,
  head: () => ({
    meta: [
      {
        title: "Metrics - FastAPI Template",
      },
    ],
  }),
})

function MetricCard({ title, value }: { title: string; value: number }) {
  return (
    <Card data-testid="metric-card">
      <CardHeader>
        <CardTitle className="text-sm font-medium text-muted-foreground">
          {title}
        </CardTitle>
      </CardHeader>
      <CardContent>
        <span className="text-3xl font-bold">{value}</span>
      </CardContent>
    </Card>
  )
}

function MetricsCards() {
  const { data: metrics } = useSuspenseQuery(getMetricsQueryOptions())

  const cards = [
    { title: "Total users", value: metrics.total_users },
    { title: "Active users", value: metrics.active_users },
    { title: "Total items", value: metrics.total_items },
    ...ROLES.map((role) => ({
      title: `${ROLE_LABELS[role]} users`,
      value: metrics.users_by_role[role] ?? 0,
    })),
  ]

  return (
    <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      {cards.map((card) => (
        <MetricCard key={card.title} title={card.title} value={card.value} />
      ))}
    </div>
  )
}

function PendingMetrics() {
  return (
    <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      {Array.from({ length: 6 }).map((_, index) => (
        <Skeleton key={index} className="h-32 rounded-xl" />
      ))}
    </div>
  )
}

function Metrics() {
  return (
    <RequirePermission permission="metrics:read">
      <div className="flex flex-col gap-6">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Metrics</h1>
          <p className="text-muted-foreground">Overview of users and items</p>
        </div>
        <Suspense fallback={<PendingMetrics />}>
          <MetricsCards />
        </Suspense>
      </div>
    </RequirePermission>
  )
}
