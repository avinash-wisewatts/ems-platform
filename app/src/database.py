from contextlib import asynccontextmanager
from typing import AsyncIterator

from psycopg import AsyncConnection
from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

from src.config import get_settings


# The pool must not be constructed during module import.
#
# Importing application modules is common during unit-test collection. Creating
# Settings or database resources here would force every unit test to provide
# production-style database credentials even when the test never uses the
# database.
_pool: AsyncConnectionPool | None = None


def get_database_pool() -> AsyncConnectionPool:
    """
    Return the initialized application database pool.

    The pool is created by open_database_pool() during FastAPI startup. Calling
    this function before startup is a programming/configuration error.
    """

    if _pool is None:
        raise RuntimeError(
            "Database pool is not initialized. "
            "Call open_database_pool() during application startup."
        )

    return _pool


async def open_database_pool() -> None:
    """
    Create and open the application connection pool during service startup.

    Settings are loaded lazily here rather than during module import.
    """

    global _pool

    # Avoid creating a second pool if startup is invoked more than once.
    if _pool is not None:
        return

    settings = get_settings()

    pool = AsyncConnectionPool(
        conninfo=settings.database_dsn,
        min_size=1,
        max_size=5,
        open=False,
        kwargs={
            "autocommit": False,
            "row_factory": dict_row,
        },
    )

    try:
        await pool.open()
        await pool.wait()
    except Exception:
        # Ensure a partially opened pool is not retained globally.
        await pool.close()
        raise

    _pool = pool


async def close_database_pool() -> None:
    """
    Close database connections during graceful shutdown.

    Closing is safe even when startup failed before creating the pool.
    """

    global _pool

    if _pool is None:
        return

    pool = _pool
    _pool = None

    await pool.close()


@asynccontextmanager
async def database_connection() -> AsyncIterator[AsyncConnection]:
    """Provide a pooled PostgreSQL connection."""

    pool = get_database_pool()

    async with pool.connection() as connection:
        yield connection
