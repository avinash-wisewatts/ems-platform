"""FastAPI dependencies for active administration context."""

from fastapi import Request

from src.context.models import AdministrationContext
from src.context.service import (
    require_location_context,
    require_organization_context,
    require_site_context,
)


def organization_context(request: Request) -> AdministrationContext:
    return require_organization_context(request)


def site_context(request: Request) -> AdministrationContext:
    return require_site_context(request)


def location_context(request: Request) -> AdministrationContext:
    return require_location_context(request)
