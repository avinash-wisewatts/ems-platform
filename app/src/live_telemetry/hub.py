import asyncio
from collections import defaultdict
from dataclasses import dataclass
from uuid import UUID

from fastapi import WebSocket


class AssetLiveHub:
    """Portal-session subscribers keyed by asset."""

    def __init__(self) -> None:
        self._subscribers: dict[str, set[WebSocket]] = defaultdict(set)
        self._lock = asyncio.Lock()

    async def add(self, asset_id: UUID, websocket: WebSocket) -> None:
        async with self._lock:
            self._subscribers[str(asset_id)].add(websocket)

    async def remove(self, asset_id: UUID, websocket: WebSocket) -> None:
        async with self._lock:
            subscribers = self._subscribers.get(str(asset_id))
            if not subscribers:
                return
            subscribers.discard(websocket)
            if not subscribers:
                self._subscribers.pop(str(asset_id), None)

    async def subscribers_for(self, asset_id: UUID) -> tuple[WebSocket, ...]:
        async with self._lock:
            return tuple(self._subscribers.get(str(asset_id), ()))


@dataclass(frozen=True)
class GrafanaStreamSubscriber:
    websocket: WebSocket
    grafana_org_id: int


class GrafanaAssetLiveHub:
    """Service-authenticated Grafana adapter subscribers keyed by asset."""

    def __init__(self) -> None:
        self._subscribers: dict[str, set[GrafanaStreamSubscriber]] = defaultdict(set)
        self._lock = asyncio.Lock()

    async def add(self, asset_id: UUID, websocket: WebSocket, grafana_org_id: int) -> None:
        async with self._lock:
            self._subscribers[str(asset_id)].add(
                GrafanaStreamSubscriber(websocket=websocket, grafana_org_id=grafana_org_id)
            )

    async def remove(self, asset_id: UUID, websocket: WebSocket, grafana_org_id: int) -> None:
        async with self._lock:
            subscribers = self._subscribers.get(str(asset_id))
            if not subscribers:
                return
            subscribers.discard(
                GrafanaStreamSubscriber(websocket=websocket, grafana_org_id=grafana_org_id)
            )
            if not subscribers:
                self._subscribers.pop(str(asset_id), None)

    async def subscribers_for(self, asset_id: UUID) -> tuple[GrafanaStreamSubscriber, ...]:
        async with self._lock:
            return tuple(self._subscribers.get(str(asset_id), ()))
