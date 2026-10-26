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
"""

from __future__ import annotations

import json
from base64 import b64decode
from http.cookies import CookieError, SimpleCookie
from urllib.parse import urlsplit

import itsdangerous
from itsdangerous.exc import BadSignature

from src.auth.audience import customer_audience
from src.auth.models import AuthenticatedPortalUser
from src.auth.session import SESSION_IDENTITY_KEY, deserialize_authenticated_user


def read_customer_identity(
    cookie_header: str | None,
    *,
    secret: str,
    cookie_name: str,
    max_age_seconds: int,
    allow_staff: bool,
) -> AuthenticatedPortalUser | None:
    """The identity in a valid, unexpired customer session cookie, else None.

    Fails closed on anything unexpected: missing or malformed cookie, bad or
    expired signature, undecodable payload, invalid identity, or an identity
    outside the customer audience.
    """

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
    if not isinstance(session, dict):
        return None
    identity = deserialize_authenticated_user(session.get(SESSION_IDENTITY_KEY))
    if identity is None or not customer_audience(allow_staff=allow_staff)(identity):
        return None
    return identity


def same_origin(origin: str | None, host: str | None) -> bool:
    """True when an Origin header names exactly the host the request reached."""

    if not origin or not host or origin == "null":
        return False
    return urlsplit(origin).netloc.lower() == host.lower()
