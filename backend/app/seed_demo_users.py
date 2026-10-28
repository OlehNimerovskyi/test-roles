import logging
import sys

from sqlmodel import Session

from app import crud
from app.core.config import settings
from app.core.db import engine
from app.core.permissions import UserRole
from app.models import UserCreate

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# The admin is created by initial_data.py from FIRST_SUPERUSER
DEMO_USERS = [
    ("manager@example.com", "Demo Manager", UserRole.MANAGER),
    ("member@example.com", "Demo Member", UserRole.MEMBER),
]


def seed(session: Session) -> None:
    for email, full_name, role in DEMO_USERS:
        if crud.get_user_by_email(session=session, email=email):
            logger.info("Demo user %s already exists, skipping", email)
            continue
        user_in = UserCreate(
            email=email,
            full_name=full_name,
            password=settings.FIRST_SUPERUSER_PASSWORD,
            role=role,
        )
        crud.create_user(session=session, user_create=user_in)
        logger.info("Created demo user %s with role %s", email, role)


def main() -> None:
    if settings.FASTAPI_ENV != "development":
        logger.error("Demo users can only be seeded when FASTAPI_ENV=development")
        sys.exit(1)
    with Session(engine) as session:
        seed(session)


if __name__ == "__main__":
    main()
