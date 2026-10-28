from typing import cast

import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session

from app.core.config import settings
from app.core.permissions import ROLE_PERMISSIONS, UserRole, permissions_for
from tests.utils.user import create_random_user, random_user_token_headers
from tests.utils.utils import random_email, random_lower_string

USERS_URL = f"{settings.API_V1_STR}/users"
METRICS_URL = f"{settings.API_V1_STR}/metrics/"

RoleHeaders = dict[UserRole, dict[str, str]]


@pytest.fixture(scope="module")
def headers_by_role(client: TestClient, db: Session) -> RoleHeaders:
    return {
        role: random_user_token_headers(client=client, db=db, role=role)
        for role in UserRole
    }


def test_every_role_has_a_permission_set() -> None:
    assert set(ROLE_PERMISSIONS) == set(UserRole)


def test_unknown_role_is_denied_everything() -> None:
    assert permissions_for(cast(UserRole, "retired-role")) == frozenset()


@pytest.mark.parametrize(
    ("role", "expected_status"),
    [(UserRole.ADMIN, 200), (UserRole.MANAGER, 200), (UserRole.MEMBER, 403)],
)
def test_list_users_allowed_for_admin_and_manager_only(
    client: TestClient,
    headers_by_role: RoleHeaders,
    role: UserRole,
    expected_status: int,
) -> None:
    r = client.get(f"{USERS_URL}/", headers=headers_by_role[role])
    assert r.status_code == expected_status


@pytest.mark.parametrize(
    ("role", "expected_status"),
    [(UserRole.ADMIN, 200), (UserRole.MANAGER, 403), (UserRole.MEMBER, 403)],
)
def test_create_user_is_admin_only(
    client: TestClient,
    headers_by_role: RoleHeaders,
    role: UserRole,
    expected_status: int,
) -> None:
    data = {"email": random_email(), "password": random_lower_string()}
    r = client.post(f"{USERS_URL}/", headers=headers_by_role[role], json=data)
    assert r.status_code == expected_status


@pytest.mark.parametrize(
    ("role", "expected_status"),
    [(UserRole.ADMIN, 200), (UserRole.MANAGER, 403), (UserRole.MEMBER, 403)],
)
def test_update_other_user_is_admin_only(
    client: TestClient,
    db: Session,
    headers_by_role: RoleHeaders,
    role: UserRole,
    expected_status: int,
) -> None:
    other_user = create_random_user(db)
    r = client.patch(
        f"{USERS_URL}/{other_user.id}",
        headers=headers_by_role[role],
        json={"full_name": "Changed"},
    )
    assert r.status_code == expected_status


@pytest.mark.parametrize(
    ("role", "expected_status"),
    [(UserRole.ADMIN, 200), (UserRole.MANAGER, 200), (UserRole.MEMBER, 403)],
)
def test_metrics_allowed_for_admin_and_manager_only(
    client: TestClient,
    headers_by_role: RoleHeaders,
    role: UserRole,
    expected_status: int,
) -> None:
    r = client.get(METRICS_URL, headers=headers_by_role[role])
    assert r.status_code == expected_status


def test_metrics_reports_users_by_role(
    client: TestClient, headers_by_role: RoleHeaders
) -> None:
    r = client.get(METRICS_URL, headers=headers_by_role[UserRole.ADMIN])
    metrics = r.json()
    assert set(metrics["users_by_role"]) == set(UserRole)
    assert sum(metrics["users_by_role"].values()) == metrics["total_users"]


@pytest.mark.parametrize("role", list(UserRole))
def test_current_user_exposes_permissions_of_their_role(
    client: TestClient, headers_by_role: RoleHeaders, role: UserRole
) -> None:
    r = client.get(f"{USERS_URL}/me", headers=headers_by_role[role])
    assert r.status_code == 200
    assert r.json()["role"] == role
    assert r.json()["permissions"] == sorted(permissions_for(role))


def test_member_cannot_escalate_role_via_profile_update(
    client: TestClient, db: Session
) -> None:
    headers = random_user_token_headers(client=client, db=db, role=UserRole.MEMBER)

    r = client.patch(f"{USERS_URL}/me", headers=headers, json={"role": "admin"})

    assert r.status_code == 200
    assert r.json()["role"] == UserRole.MEMBER
    assert client.get(f"{USERS_URL}/", headers=headers).status_code == 403


def test_signup_always_creates_member(client: TestClient) -> None:
    data = {
        "email": random_email(),
        "password": random_lower_string(),
        "role": "admin",
    }
    r = client.post(f"{USERS_URL}/signup", json=data)
    assert r.status_code == 200
    assert r.json()["role"] == UserRole.MEMBER


def test_admin_cannot_change_own_role(
    client: TestClient, headers_by_role: RoleHeaders
) -> None:
    admin_headers = headers_by_role[UserRole.ADMIN]
    admin_id = client.get(f"{USERS_URL}/me", headers=admin_headers).json()["id"]

    r = client.patch(
        f"{USERS_URL}/{admin_id}", headers=admin_headers, json={"role": "member"}
    )

    assert r.status_code == 403
    me = client.get(f"{USERS_URL}/me", headers=admin_headers).json()
    assert me["role"] == UserRole.ADMIN


def test_role_change_applies_to_already_issued_tokens(
    client: TestClient, db: Session, headers_by_role: RoleHeaders
) -> None:
    manager_headers = random_user_token_headers(
        client=client, db=db, role=UserRole.MANAGER
    )
    manager_id = client.get(f"{USERS_URL}/me", headers=manager_headers).json()["id"]
    assert client.get(f"{USERS_URL}/", headers=manager_headers).status_code == 200

    client.patch(
        f"{USERS_URL}/{manager_id}",
        headers=headers_by_role[UserRole.ADMIN],
        json={"role": "member"},
    )

    assert client.get(f"{USERS_URL}/", headers=manager_headers).status_code == 403


def test_request_without_token_is_unauthorized(client: TestClient) -> None:
    r = client.get(f"{USERS_URL}/me")
    assert r.status_code == 401


def test_request_with_invalid_token_is_unauthorized(client: TestClient) -> None:
    r = client.get(f"{USERS_URL}/me", headers={"Authorization": "Bearer invalid"})
    assert r.status_code == 401
    assert r.headers["WWW-Authenticate"] == "Bearer"
