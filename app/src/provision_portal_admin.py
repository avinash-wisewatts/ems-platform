"""Provision the initial EMS Web App administrator (default username admin_user).

Uses the existing user-management infrastructure only: the account is created
by admin.create_managed_portal_user -- the same controlled, audited function the
Administration App's Users page calls -- on behalf of an EXISTING active GLOBAL
administrator (--actor-username), so the audit trail (admin.portal_user_audit,
USER_CREATED) records who provisioned it. Role ADMIN with GLOBAL scope: the
highest-privilege role of the three-role model, with WiseWatts-staff reach.

Safety:
- An existing account with the username is never modified, re-activated or
  given a new password: the command stops and changes nothing.
- The password is generated here (operating-system CSPRNG, src.user_account_policy),
  hashed with the portal's Argon2id parameters, and only the hash reaches the
  database. It is never logged and never passed on a command line.
- It is handed over exactly once: written to a NEW file (--password-file,
  created exclusively, owner-read/write only) or, without --password-file,
  printed to an interactive terminal -- never to a pipe or log.
- The password file is prepared BEFORE the account is created, so an account
  is never left with a password nobody received.

The account signs in through the existing Administration App /login (it is
staff, so EMS_ADMIN_STAFF_ONLY does not affect it) and reaches the EMS Web App
at /app. There is no forced change at first sign-in (the portal does not
support it): change the temporary password in Admin -> Users -> your account
-> Change my password.

Run where the application's database settings are configured, e.g. inside the
admin-portal container:

  python -m src.provision_portal_admin --actor-username <existing global admin> \
      --email admin@example.com --password-file /run/admin_user_password.txt

Exit codes: 0 created; 2 invalid input / actor; 3 username already exists
(nothing changed); 4 database refused; 5 password destination unavailable.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys
from dataclasses import dataclass
from typing import TextIO

from psycopg.errors import DatabaseError

from src.auth.repository import get_portal_user_for_authentication
from src.auth.security import hash_portal_password
from src.database import close_database_pool, open_database_pool
from src.user_account_policy import (
    AccountPolicyError,
    generate_temporary_password,
    normalize_display_name,
    normalize_email,
    normalize_username,
)
from src.user_management_service import create_managed_user

EXIT_CREATED = 0
EXIT_INVALID = 2
EXIT_EXISTS = 3
EXIT_DATABASE = 4
EXIT_DESTINATION = 5


@dataclass
class PasswordDestination:
    """Where the one-time password goes: an exclusive new file or the terminal.

    The file is created exclusively (O_EXCL, never following a symlink, owner
    read/write only) BEFORE the account is created, and the password is
    written through that same open handle -- the path is never reopened, so
    nothing can be swapped in between.
    """

    path: str | None
    stream: TextIO
    handle: TextIO | None = None

    @classmethod
    def prepare(cls, path: str | None, stream: TextIO) -> "PasswordDestination":
        if path is None:
            if not stream.isatty():
                raise OSError(
                    "Refusing to print a password to a non-interactive output; use --password-file."
                )
            return cls(path=None, stream=stream)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags, 0o600)
        try:
            handle = os.fdopen(descriptor, "w", encoding="utf-8")
        except BaseException:
            os.close(descriptor)
            raise
        return cls(path=path, stream=stream, handle=handle)

    def deliver(self, username: str, password: str) -> None:
        if self.handle is None:
            self.stream.write(
                "\nOne-time initial password for "
                f"{username} (shown once, not stored anywhere):\n\n    {password}\n\n"
            )
            self.stream.flush()
            return
        with self.handle:
            self.handle.write(f"{password}\n")
            self.handle.flush()
            os.fsync(self.handle.fileno())
        self.handle = None

    def discard(self) -> None:
        """Close and remove the (still empty) file this run created."""

        if self.handle is None or self.path is None:
            return
        try:
            created = os.fstat(self.handle.fileno())
            self.handle.close()
            current = os.lstat(self.path)
            # Remove only the file this run created, never a replacement.
            if (current.st_dev, current.st_ino) == (created.st_dev, created.st_ino):
                os.remove(self.path)
        except FileNotFoundError:
            pass
        finally:
            self.handle = None


async def provision(
    *,
    username: str,
    display_name: str,
    email: str,
    actor_username: str,
    password_file: str | None,
    out: TextIO = sys.stdout,
    err: TextIO = sys.stderr,
) -> int:
    try:
        username = normalize_username(username)
        display_name = normalize_display_name(display_name)
        email = normalize_email(email)
        actor_username = normalize_username(actor_username)
    except AccountPolicyError as exc:
        err.write(f"Invalid input: {exc}\n")
        return EXIT_INVALID

    if await get_portal_user_for_authentication(username) is not None:
        err.write(
            f"A portal user named {username!r} already exists. Nothing was changed "
            "(no password reset, no re-activation). Reset it from Admin -> Users if intended.\n"
        )
        return EXIT_EXISTS

    actor = await get_portal_user_for_authentication(actor_username)
    if (
        actor is None
        or not actor.is_active
        or actor.role_code != "ADMIN"
        or actor.access_scope_mode != "GLOBAL"
    ):
        err.write("--actor-username must be an existing, active GLOBAL administrator.\n")
        return EXIT_INVALID

    try:
        destination = PasswordDestination.prepare(password_file, out)
    except OSError as exc:
        err.write(f"Password destination unavailable: {exc}\n")
        return EXIT_DESTINATION

    password = generate_temporary_password()
    try:
        portal_user_id = await create_managed_user(
            actor_portal_user_id=actor.portal_user_id,
            username=username,
            display_name=display_name,
            email=email,
            password_hash=hash_portal_password(password),
            role_code="ADMIN",
            access_scope_mode="GLOBAL",
            organization_id=None,
            site_ids=(),
        )
    except DatabaseError as exc:
        destination.discard()
        if getattr(exc, "sqlstate", None) == "23505":
            err.write(f"A portal user named {username!r} (or with that email) already exists. Nothing was changed.\n")
            return EXIT_EXISTS
        err.write("The database refused to create the account. Nothing was changed.\n")
        return EXIT_DATABASE
    except BaseException:
        # Anything else (connection lost, interrupted): leave no empty
        # password file behind.
        destination.discard()
        raise

    destination.deliver(username, password)
    out.write(
        f"Created portal user {username!r} (id {portal_user_id}): role ADMIN, scope GLOBAL, active; "
        f"audited as created by {actor_username!r}.\n"
    )
    if destination.path is not None:
        out.write(
            f"The one-time password was written to {destination.path} (owner-only). "
            "Read it, then delete the file.\n"
        )
    out.write("Change it after the first sign-in: Admin -> Users -> your account -> Change my password.\n")
    return EXIT_CREATED


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--username", default="admin_user")
    parser.add_argument("--display-name", default="EMS Administrator")
    parser.add_argument("--email", required=True)
    parser.add_argument(
        "--actor-username",
        required=True,
        help="An existing active GLOBAL administrator recorded as the creator in the audit trail.",
    )
    parser.add_argument(
        "--password-file",
        help="A NEW file to receive the one-time password (owner-only). Default: print to the terminal.",
    )
    args = parser.parse_args(argv)

    async def run() -> int:
        await open_database_pool()
        try:
            return await provision(
                username=args.username,
                display_name=args.display_name,
                email=args.email,
                actor_username=args.actor_username,
                password_file=args.password_file,
            )
        finally:
            await close_database_pool()

    return asyncio.run(run())


if __name__ == "__main__":
    raise SystemExit(main())
