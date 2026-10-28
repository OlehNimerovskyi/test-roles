from fastapi import APIRouter, Depends
from sqlmodel import col, func, select

from app.api.deps import SessionDep, require_permission
from app.core.permissions import Permission, UserRole
from app.models import Item, MetricsPublic, User

router = APIRouter(
    prefix="/metrics",
    tags=["metrics"],
    dependencies=[Depends(require_permission(Permission.METRICS_READ))],
)


@router.get("/")
def read_metrics(session: SessionDep) -> MetricsPublic:
    total_users = session.exec(select(func.count()).select_from(User)).one()
    active_users = session.exec(
        select(func.count()).select_from(User).where(col(User.is_active).is_(True))
    ).one()
    role_counts = session.exec(
        select(User.role, func.count()).group_by(col(User.role))
    ).all()
    total_items = session.exec(select(func.count()).select_from(Item)).one()

    return MetricsPublic(
        total_users=total_users,
        active_users=active_users,
        users_by_role=dict.fromkeys(UserRole, 0)
        | {UserRole(role): count for role, count in role_counts},
        total_items=total_items,
    )
