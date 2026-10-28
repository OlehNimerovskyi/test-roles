"""Replace is_superuser with role

Revision ID: 74a2398a7a80
Revises: fe56fa70289e
Create Date: 2026-10-28 14:00:00.000000

"""
from alembic import op
import sqlalchemy as sa
import sqlmodel.sql.sqltypes


# revision identifiers, used by Alembic.
revision = '74a2398a7a80'
down_revision = 'fe56fa70289e'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        'user',
        sa.Column(
            'role',
            sqlmodel.sql.sqltypes.AutoString(length=32),
            nullable=False,
            server_default='member',
        ),
    )
    op.execute("UPDATE \"user\" SET role = 'admin' WHERE is_superuser")
    op.drop_column('user', 'is_superuser')


def downgrade():
    # Lossy: there is no is_superuser equivalent for managers, so they become regular users
    op.add_column(
        'user',
        sa.Column('is_superuser', sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.execute("UPDATE \"user\" SET is_superuser = true WHERE role = 'admin'")
    op.drop_column('user', 'role')
