from enum import StrEnum


class UserRole(StrEnum):
    ADMIN = "admin"
    MANAGER = "manager"
    MEMBER = "member"


class Permission(StrEnum):
    USERS_READ = "users:read"
    USERS_CREATE = "users:create"
    USERS_UPDATE = "users:update"
    USERS_DELETE = "users:delete"
    METRICS_READ = "metrics:read"
    ITEMS_MANAGE_ALL = "items:manage_all"
    SETTINGS_MANAGE = "settings:manage"


ROLE_PERMISSIONS: dict[UserRole, frozenset[Permission]] = {
    UserRole.ADMIN: frozenset(Permission),
    UserRole.MANAGER: frozenset({Permission.USERS_READ, Permission.METRICS_READ}),
    UserRole.MEMBER: frozenset(),
}


def permissions_for(role: UserRole) -> frozenset[Permission]:
    # Deny by default: an unknown role (e.g. a stale DB value) grants nothing
    return ROLE_PERMISSIONS.get(role, frozenset())


def has_permission(role: UserRole, permission: Permission) -> bool:
    return permission in permissions_for(role)
