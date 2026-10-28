import type { ReactNode } from "react"

import type { Permission } from "@/client"
import usePermissions from "@/hooks/usePermissions"
import Forbidden from "./Forbidden"

interface RequirePermissionProps {
  permission: Permission
  children: ReactNode
}

const RequirePermission = ({
  permission,
  children,
}: RequirePermissionProps) => {
  const { can, isLoaded } = usePermissions()

  if (!isLoaded) {
    return null
  }

  if (!can(permission)) {
    return <Forbidden />
  }

  return <>{children}</>
}

export default RequirePermission
