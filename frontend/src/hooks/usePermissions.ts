import type { Permission } from "@/client"
import useAuth from "./useAuth"

const usePermissions = () => {
  const { user } = useAuth()

  const can = (permission: Permission) =>
    user?.permissions.includes(permission) ?? false

  return { can, isLoaded: Boolean(user) }
}

export default usePermissions
