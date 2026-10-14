"""Shared in-memory helpers for the Phase 4 hive tests (no aiortc needed)."""

import asyncio
import time
from contextlib import asynccontextmanager
from types import SimpleNamespace
from uuid import uuid4

from sqlalchemy import select

from subconscious_engine.api.app import create_app
from subconscious_engine.api.schemas import CreateThreadRequest, CreateWorkspaceRequest, UpdateThreadRequest
from subconscious_engine.auth import EngineAuthToken
from subconscious_engine.hive import authz
from subconscious_engine.hive.channels import Envelope
from subconscious_engine.hive.directory import Directory, PinStore
from subconscious_engine.hive.identity import NodeIdentity, approval_message
from subconscious_engine.hive.node import HiveNode
from subconscious_engine.services.messages import message_order
from subconscious_engine.services.threads import ThreadService
from subconscious_engine.services.workspaces import WorkspaceService
from subconscious_engine.storage import Database
from subconscious_engine.storage.models import (
    ConversationThread,
    Message,
    TaskRecord,
    Workspace,
)

USER = "user-1"
HIVE = "hive-1"


def entry(identity, *, kind="engine", approver=None, status="active"):
    sig = approver.sign(approval_message(USER, identity.public_key_b64u)) if approver else None
    return {
        "id": identity.node_id, "kind": kind, "name": f"n-{identity.node_id[2:6]}", "platform": "test",
        "app_version": "0", "protocol_version": 1, "public_key": identity.public_key_b64u,
        "status": status, "approved_by": approver.node_id if approver else None, "approval_sig": sig,
        "capabilities": {}, "online": True,
    }


def make_entries(root, *others):
    """``others`` are ``(identity, kind)``; every one is approved by ``root``."""
    return [entry(root)] + [entry(identity, kind=kind, approver=root) for identity, kind in others]


def directory_for(local, entries, hive_id=HIVE):
    directory = Directory(USER, local.node_id, PinStore(None))
    directory.update(list(entries), hive_id)
    return directory


async def until(predicate, timeout=20.0, step=0.02):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if asyncio.iscoroutine(result):
            result = await result
        if result:
            return True
        await asyncio.sleep(step)
    raise AssertionError("condition not reached in time")


class MemLink:
    """Duck-typed ``PeerLink`` whose frames go straight to the other end's handler."""

    def __init__(self, local_id, remote_id, role, loop):
        self.node_id, self.local_id, self.role, self.tier = remote_id, local_id, role, "direct"
        self.handler = None
        self.created = time.time() + len(str(uuid4())) * 1e-9
        self.closed = asyncio.Event()
        self.peer = None
        self.sent = []
        self.drop = False
        self._loop = loop

    async def send(self, channel, envelope):
        if self.closed.is_set():
            raise ConnectionError("closed")
        self.sent.append((channel, envelope))
        if self.drop or self.peer is None:
            return
        wire = Envelope(envelope.type, envelope.data, envelope.id, self.local_id, self.node_id)
        target = self.peer
        self._loop.call_soon(lambda: target.handler and target.handler(target, channel, wire))

    async def close(self):
        for link in (self, self.peer):
            if link is not None:
                link.closed.set()


class MemPeers:
    def __init__(self):
        self._links = {}

    @property
    def links(self):
        return {k: v for k, v in self._links.items() if not v.closed.is_set()}

    def link(self, node_id):
        link = self._links.get(node_id)
        return link if link is not None and not link.closed.is_set() else None


class MemEngine:
    """A whole engine: database, ASGI app, hive node on in-memory links."""

    def __init__(self, tmp_path, name, identity, entries, *, hive_id=HIVE, agent_manager=None, ttl=None):
        self.name, self.identity, self.hive_id = name, identity, hive_id
        self.database = Database(tmp_path / f"{name}.db")
        store = SimpleNamespace()

        async def resolve(identifier):
            return None

        async def listing():
            return []

        store.resolve, store.list = resolve, listing
        self.app = create_app(self.database, EngineAuthToken("secret-token"),
                              model_configuration_store=store, agent_manager=agent_manager)
        if ttl is not None:
            self.app.state.task_manager.ttl_seconds = ttl
        self.directory = directory_for(identity, entries, hive_id)
        self.node = HiveNode(self.app, identity, self.directory)
        self.peers = MemPeers()
        self.node.peers = self.peers
        self.engine = self.app.state.sync_engine
        self.tasks = self.app.state.task_manager

    async def start(self):
        await self.database.initialize()
        assert await self.node.start(self.hive_id)

    async def stop(self):
        await self.node.stop()
        await self.database.close()

    # --- local writes through the real services (so the sync hooks fire) ---
    async def workspace(self, name="W", description=None):
        async with self.database.session() as session:
            dto = await WorkspaceService(session).create(
                CreateWorkspaceRequest(name=name, description=description))
        return dto.uuid

    async def thread(self, workspace_uuid, title="T"):
        async with self.database.session() as session:
            dto = await ThreadService(session).create(
                CreateThreadRequest(workspace_uuid=workspace_uuid, title=title))
        return dto.uuid

    async def rename(self, thread_uuid, title):
        async with self.database.session() as session:
            service = ThreadService(session)
            row = await service.get(thread_uuid)
            await service.update(row, UpdateThreadRequest(title=title))

    async def delete_thread(self, thread_uuid):
        async with self.database.session() as session:
            service = ThreadService(session)
            await service.delete(await service.get(thread_uuid))

    async def delete_workspace(self, workspace_uuid):
        async with self.database.session() as session:
            service = WorkspaceService(session)
            await service.delete(await service.get(workspace_uuid))

    async def message(self, thread_uuid, content, role="user"):
        async with self.database.session() as session:
            thread = await session.scalar(select(ConversationThread).where(ConversationThread.uuid == thread_uuid))
            row = Message(uuid=str(uuid4()), thread_id=thread.id, role=role, content=content)
            session.add(row)
            await session.commit()
            return row.uuid

    async def fingerprint(self):
        async with self.database.session() as session:
            workspaces = {w.uuid: (w.name, w.description, w.deleted_at is not None)
                          for w in (await session.scalars(select(Workspace))).all()}
            threads, messages, order = {}, {}, {}
            for t in (await session.scalars(select(ConversationThread))).all():
                workspace = await session.get(Workspace, t.workspace_id)
                threads[t.uuid] = (workspace.uuid, t.title, t.description, t.default_model_id,
                                   t.deleted_at is not None)
                rows = (await session.scalars(
                    select(Message).where(Message.thread_id == t.id).order_by(*message_order()))).all()
                order[t.uuid] = [m.uuid for m in rows]
                for m in rows:
                    messages[m.uuid] = (t.uuid, m.role, m.content, m.deleted_at is not None)
            tasks = {r.task_id: (r.thread_uuid, r.executor_node_id, r.requester_node_id, r.status, r.rev,
                                 r.client_msg_uuid)
                     for r in (await session.scalars(select(TaskRecord))).all()}
        return {"workspaces": workspaces, "threads": threads, "messages": messages, "order": order,
                "tasks": tasks}

    async def task_rows(self):
        async with self.database.session() as session:
            return (await session.scalars(select(TaskRecord))).all()


def connect(a, b, *, role_a=authz.HIVE_PEER, role_b=authz.HIVE_PEER):
    """Open an in-memory link between two engines (``role_x`` is how x sees the other end)."""
    loop = asyncio.get_running_loop()
    la = MemLink(a.identity.node_id, b.identity.node_id, role_a, loop)
    lb = MemLink(b.identity.node_id, a.identity.node_id, role_b, loop)
    la.peer, lb.peer = lb, la
    a.peers._links[b.identity.node_id] = la
    b.peers._links[a.identity.node_id] = lb
    a.node.on_link(la)
    b.node.on_link(lb)
    return la, lb


class MemThin:
    """A thin client: no engine, just frames in and out of one engine."""

    def __init__(self, engine, identity):
        self.identity = identity
        self.frames = []
        loop = asyncio.get_running_loop()
        self.to_engine = MemLink(identity.node_id, engine.identity.node_id, authz.HIVE_PEER, loop)
        self.from_engine = MemLink(engine.identity.node_id, identity.node_id, authz.THIN_CLIENT, loop)
        self.to_engine.peer, self.from_engine.peer = self.from_engine, self.to_engine
        self.to_engine.handler = lambda link, channel, env: self.frames.append(env)
        engine.peers._links[identity.node_id] = self.from_engine
        engine.node.on_link(self.from_engine)

    async def send(self, frame_type, data, identifier=None):
        await self.to_engine.send("control", Envelope(frame_type, data, identifier))

    def of_type(self, frame_type):
        return [f for f in self.frames if f.type == frame_type]


@asynccontextmanager
async def mesh(tmp_path, names, *, thin=(), **engine_options):
    """Engines ``names`` (first is the trust root) plus optional thin identities."""
    identities = {name: NodeIdentity.generate() for name in names}
    thins = {name: NodeIdentity.generate() for name in thin}
    root = identities[names[0]]
    entries = make_entries(
        root,
        *[(identities[n], "engine") for n in names[1:]],
        *[(thins[n], "thin") for n in thin],
    )
    engines = {n: MemEngine(tmp_path, n, identities[n], entries, **engine_options) for n in names}
    for engine in engines.values():
        await engine.start()
    try:
        yield engines, thins
    finally:
        for engine in engines.values():
            await engine.stop()


async def converged(*engines, timeout=20.0):
    async def same():
        prints = [await e.fingerprint() for e in engines]
        return all(p == prints[0] for p in prints[1:])

    await until(same, timeout)
    return await engines[0].fingerprint()
