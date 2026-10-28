"""Read a customer-API session outside the customer API (ADR-023 stage 3).

live-telemetry serves the customer host's /api/live/* directly (the edge
proxy routes it there), so it must recognise the customer session cookie as
well as the Administration App's. The customer API issues that cookie with
Starlette's SessionMiddleware under its own name and signing secret; this
module verifies it the same way (itsdangerous TimestampSigner over base64
JSON, with the same max age) without installing a second SessionMiddleware.

Also: the same-origin test for browser WebSocket handshakes that carry the
customer cookie. Browsers attach cookies to cross-site WebSocket handshakes,
so without it any web page could open a live stream as a signed-in customer.

Server-side sessions (migration 314): the cookie also carries a random
session token, and the database holds only its SHA-256
(admin.portal_sessions). A signed cookie alone is no longer enough -- its
token must still name a live, unrevoked session of an active account, so
sign-out, deactivation and a password change end every copy of the cookie.
"""

from __future__ import annotations

import hashlib
import json
import secrets
from base64 import b64decode
from dataclasses import dataclass
from http.cookies import CookieError, SimpleCookie
from urllib.parse import urlsplit

import itsdangerous
from itsdangerous.exc import BadSignature

from src.auth.audience import customer_audience
from src.auth.models import AuthenticatedPortalUser
from src.auth.session import SESSION_IDENTITY_KEY, deserialize_authenticated_user

# Session key of the server-side session token; admin.portal_sessions.audience.
SESSION_TOKEN_KEY = "session_token"
CUSTOMER_AUDIENCE = "CUSTOMER"


def new_session_token() -> str:
    """A new random session token (256 bits)."""

    return secrets.token_urlsafe(32)


def session_token_hash(token: str) -> bytes:
    """What the database stores and looks up: SHA-256 of the token."""

    return hashlib.sha256(token.encode("utf-8")).digest()


def session_token(session: object) -> str | None:
    """The server-side session token held in a session, else None."""

    if not isinstance(session, dict):
        return None
    token = session.get(SESSION_TOKEN_KEY)
    if not isinstance(token, str) or not token:
        return None
    return token


@dataclass(frozen=True, slots=True)
class CustomerSession:
    identity: AuthenticatedPortalUser
    token: str


def _verified_session_data(cookie_header: str | None, *, secret: str, cookie_name: str, max_age_seconds: int) -> dict | None:
    if not cookie_header:
        return None
    try:
        jar = SimpleCookie()
        jar.load(cookie_header)
    except CookieError:
        return None
    morsel = jar.get(cookie_name)
    if morsel is None or not morsel.value:
        return None
    try:
        data = itsdangerous.TimestampSigner(str(secret)).unsign(morsel.value.encode("utf-8"), max_age=max_age_seconds)
        session = json.loads(b64decode(data))
    except (BadSignature, ValueError, TypeError):
        return None
    return session if isinstance(session, dict) else None


def read_customer_session(
    cookie_header: str | None,
    *,
    secret: str,
    cookie_name: str,
    max_age_seconds: int,
    allow_staff: bool,
) -> CustomerSession | None:
    """The identity and session token of a valid, unexpired customer cookie, else None.

    Fails closed on anything unexpected: missing or malformed cookie, bad or
    expired signature, undecodable payload, no session token (a cookie
    issued before migration 314), invalid identity, or an identity outside
    the customer audience. The caller must still check the token against
    the database.
    """

    session = _verified_session_data(
        cookie_header, secret=secret, cookie_name=cookie_name, max_age_seconds=max_age_seconds
    )
    token = session_token(session)
    if session is None or token is None:
        return None
    identity = deserialize_authenticated_user(session.get(SESSION_IDENTITY_KEY))
    if identity is None or not customer_audience(allow_staff=allow_staff)(identity):
        return None
    return CustomerSession(identity=identity, token=token)


def same_origin(origin: str | None, host: str | None) -> bool:
    """True when an Origin header names exactly the host the request reached."""

    if not origin or not host or origin == "null":
        return False
    return urlsplit(origin).netloc.lower() == host.lower()
