"""WhatsApp delivery configuration (ADR-026 Phase 2, A6).

Secrets live only in server-side env files, never in the repository, the
browser, Grafana or logs:

- sender worker (``whatsapp-sender`` service): ``app/whatsapp.env``
  (EMS_WHATSAPP_ACCESS_TOKEN, EMS_WHATSAPP_PHONE_NUMBER_ID, template, allowlist)
- receipt webhook (customer API): ``app/customer-api.env``
  (EMS_WHATSAPP_APP_SECRET, EMS_WHATSAPP_WEBHOOK_VERIFY_TOKEN)

Sending needs ALL of: EMS_WHATSAPP_SENDING_ENABLED=true here, the database
kill switch (analytics.alert_whatsapp_delivery_control) on, and complete
provider settings. While EMS_WHATSAPP_RECIPIENT_ALLOWLIST is non-empty only
those numbers are ever sent to; an empty allowlist refuses every number
unless EMS_WHATSAPP_ALLOWLIST_DISABLED=true (never on staging: staging uses
WiseWatts-controlled test numbers only, D17).
"""

from __future__ import annotations

import re
from functools import lru_cache

from pydantic import Field, SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

_E164 = re.compile(r"^\+[1-9][0-9]{7,14}$")
# Seconds beyond the request timeout a lease must still have when a send starts.
SEND_MARGIN_SECONDS = 10.0


class WhatsAppSettings(BaseSettings):
    model_config = SettingsConfigDict(extra="ignore", populate_by_name=True)

    sending_enabled: bool = Field(default=False, alias="EMS_WHATSAPP_SENDING_ENABLED")
    access_token: SecretStr | None = Field(default=None, alias="EMS_WHATSAPP_ACCESS_TOKEN")
    phone_number_id: str | None = Field(default=None, alias="EMS_WHATSAPP_PHONE_NUMBER_ID")
    graph_api_base: str = Field(default="https://graph.facebook.com", alias="EMS_WHATSAPP_GRAPH_API_BASE")
    graph_api_version: str = Field(default="v26.0", alias="EMS_WHATSAPP_GRAPH_API_VERSION")
    template_name: str | None = Field(default=None, alias="EMS_WHATSAPP_TEMPLATE_NAME")
    template_language: str = Field(default="en", alias="EMS_WHATSAPP_TEMPLATE_LANGUAGE")
    recipient_allowlist: str = Field(default="", alias="EMS_WHATSAPP_RECIPIENT_ALLOWLIST")
    allowlist_disabled: bool = Field(default=False, alias="EMS_WHATSAPP_ALLOWLIST_DISABLED")

    poll_seconds: float = Field(default=5.0, ge=1.0, le=60.0, alias="EMS_WHATSAPP_POLL_SECONDS")
    batch_size: int = Field(default=10, ge=1, le=100, alias="EMS_WHATSAPP_BATCH_SIZE")
    lease_seconds: int = Field(default=300, ge=30, le=600, alias="EMS_WHATSAPP_LEASE_SECONDS")
    request_timeout_seconds: float = Field(default=15.0, ge=1.0, le=60.0, alias="EMS_WHATSAPP_REQUEST_TIMEOUT_SECONDS")

    # Receipt webhook (customer API).
    app_secret: SecretStr | None = Field(default=None, alias="EMS_WHATSAPP_APP_SECRET")
    webhook_verify_token: SecretStr | None = Field(default=None, alias="EMS_WHATSAPP_WEBHOOK_VERIFY_TOKEN")

    @field_validator("phone_number_id", "template_name")
    @classmethod
    def _blank_is_none(cls, value: str | None) -> str | None:
        return value.strip() or None if isinstance(value, str) else value

    @property
    def send_margin_seconds(self) -> float:
        """Lease time a delivery must still have before its request starts:
        the whole request plus a margin to record the outcome."""
        return self.request_timeout_seconds + SEND_MARGIN_SECONDS

    @property
    def effective_batch_size(self) -> int:
        """Deliveries are sent one after another under one lease, so claim
        only as many as the lease covers (the rest stay due for the next
        cycle rather than lapsing unsent)."""
        return max(1, min(self.batch_size, int(self.lease_seconds // self.send_margin_seconds)))

    @property
    def allowlist(self) -> frozenset[str]:
        numbers = {n.strip() for n in self.recipient_allowlist.split(",") if n.strip()}
        return frozenset(n for n in numbers if _E164.match(n))

    def allows(self, phone_e164: str) -> bool:
        """May this number be sent to? Empty allowlist = nobody, unless disabled."""
        if self.allowlist_disabled:
            return True
        return phone_e164 in self.allowlist

    def provider_problems(self) -> list[str]:
        """What prevents sending (names of settings only, never values)."""
        problems = []
        if not self.sending_enabled:
            problems.append("EMS_WHATSAPP_SENDING_ENABLED is off")
        if self.access_token is None or not self.access_token.get_secret_value().strip():
            problems.append("EMS_WHATSAPP_ACCESS_TOKEN is missing")
        if not self.phone_number_id or not self.phone_number_id.isdigit():
            problems.append("EMS_WHATSAPP_PHONE_NUMBER_ID is missing or not numeric")
        if not self.template_name:
            problems.append("EMS_WHATSAPP_TEMPLATE_NAME is missing")
        if self.lease_seconds < self.send_margin_seconds:
            problems.append("EMS_WHATSAPP_LEASE_SECONDS must exceed EMS_WHATSAPP_REQUEST_TIMEOUT_SECONDS "
                            f"by at least {SEND_MARGIN_SECONDS:.0f} s")
        if not self.allowlist_disabled and not self.allowlist:
            problems.append("EMS_WHATSAPP_RECIPIENT_ALLOWLIST is empty (no number may be sent to)")
        return problems

    @property
    def webhook_configured(self) -> bool:
        return bool(
            self.app_secret is not None
            and self.app_secret.get_secret_value()
            and self.webhook_verify_token is not None
            and self.webhook_verify_token.get_secret_value()
        )


@lru_cache
def get_whatsapp_settings() -> WhatsAppSettings:
    return WhatsAppSettings()
