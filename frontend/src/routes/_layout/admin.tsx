import { useSuspenseQuery } from "@tanstack/react-query"
import { createFileRoute } from "@tanstack/react-router"
import { Suspense } from "react"

import { type UserPublic, UsersService } from "@/client"
import AddUser from "@/components/Admin/AddUser"
import { columns, type UserTableData } from "@/components/Admin/columns"
import { DataTable } from "@/components/Common/DataTable"
import RequirePermission from "@/components/Common/RequirePermission"
import PendingUsers from "@/components/Pending/PendingUsers"
import useAuth from "@/hooks/useAuth"
import usePermissions from "@/hooks/usePermissions"

function getUsersQueryOptions() {
  return {
    queryFn: async () =>
      (await UsersService.readUsers({ query: { skip: 0, limit: 100 } })).data,
    queryKey: ["users"],
  }
}

export const Route = createFileRoute("/_layout/admin")({
  component: Admin,
  head: () => ({
    meta: [
      {
        title: "Users - FastAPI Template",
      },
    ],
  }),
})

function UsersTableContent() {
  const { user: currentUser } = useAuth()
  const { data: users } = useSuspenseQuery(getUsersQueryOptions())

  const tableData: UserTableData[] = users.data.map((user: UserPublic) => ({
    ...user,
    isCurrentUser: currentUser?.id === user.id,
  }))

  return <DataTable columns={columns} data={tableData} />
}

function UsersTable() {
  return (
    <Suspense fallback={<PendingUsers />}>
      <UsersTableContent />
    </Suspense>
  )
}

function UsersPage() {
  const { can } = usePermissions()
  const canCreateUsers = can("users:create")

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Users</h1>
          <p className="text-muted-foreground">
            {canCreateUsers
              ? "Manage user accounts and permissions"
              : "View user accounts and their roles"}
          </p>
        </div>
        {canCreateUsers && <AddUser />}
      </div>
      <UsersTable />
    </div>
  )
}

function Admin() {
  return (
    <RequirePermission permission="users:read">
      <UsersPage />
    </RequirePermission>
  )
}
