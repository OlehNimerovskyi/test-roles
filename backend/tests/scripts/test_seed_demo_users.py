import pytest
from sqlmodel import Session

from app import crud
from app.seed_demo_users import DEMO_USERS, main, seed


@pytest.fixture(autouse=True)
def without_demo_users(db: Session) -> None:
    for email, _, _ in DEMO_USERS:
        user = crud.get_user_by_email(session=db, email=email)
        if user:
            db.delete(user)
    db.commit()


def test_seed_creates_each_demo_user_once(db: Session) -> None:
    seed(db)
    seed(db)

    for email, full_name, role in DEMO_USERS:
        user = crud.get_user_by_email(session=db, email=email)
        assert user
        assert user.role == role
        assert user.full_name == full_name


def test_main_seeds_in_development(db: Session) -> None:
    main()

    for email, _, _ in DEMO_USERS:
        assert crud.get_user_by_email(session=db, email=email)


def test_main_refuses_outside_development(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr("app.seed_demo_users.settings.FASTAPI_ENV", None)

    with pytest.raises(SystemExit) as exit_info:
        main()

    assert exit_info.value.code == 1
