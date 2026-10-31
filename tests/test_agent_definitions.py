"""Agents: persistence, REST API, events and the chat management tools."""
import json

from subconscious_engine.approval import ApprovalConfig
from subconscious_engine.services.agent_tools import AgentTools

from test_api import api_client, auth, run


async def _workspace(client, name="Alpha"):
    response = await client.post("/api/v1/workspaces", headers=auth(), json={"name": name})
    assert response.status_code == 200
    return response.json()["uuid"]


def test_agent_crud_scope_and_validation(tmp_path):
    async def scenario():
        async with api_client(tmp_path) as (client, app):
            events = []
            subscription = app.state.event_bus
            original = subscription.publish

            async def spy(event_type, data):
                events.append((event_type, data))
                await original(event_type, data)

            subscription.publish = spy
            alpha = await _workspace(client)
            beta = await _workspace(client, "Beta")

            assert (await client.get("/api/v1/agents", headers=auth())).json() == []
            assert (await client.post("/api/v1/agents", headers=auth(), json={"name": " "})).status_code == 400
            assert (await client.post("/api/v1/agents", headers=auth(), content=b"{")).status_code == 400
            missing_workspace = await client.post(
                "/api/v1/agents", headers=auth(), json={"name": "X", "workspaceUuid": "nope"})
            assert missing_workspace.status_code == 400
            assert missing_workspace.json() == {"error": "Workspace not found."}
            bad_tools = await client.post(
                "/api/v1/agents", headers=auth(), json={"name": "X", "toolsConfig": "[1]"})
            assert bad_tools.status_code == 400

            created = await client.post("/api/v1/agents", headers=auth(), json={
                "name": "Researcher", "description": "Finds things", "instructions": "Be thorough.",
                "workspaceUuid": alpha, "toolsConfig": json.dumps({"builtin_enabled": False}),
                "approvalConfig": json.dumps({"read": False})})
            assert created.status_code == 201
            agent = created.json()
            assert agent["workspaceUuid"] == alpha and agent["enabled"] is True
            assert agent["toolsConfig"] == '{"builtin_enabled": false}'
            assert created.headers["location"] == f"/api/v1/agents/{agent['uuid']}"

            wide = (await client.post("/api/v1/agents", headers=auth(), json={"name": "Helper"})).json()
            assert wide["workspaceUuid"] is None
            # Same name is fine in another scope, not twice in one.
            assert (await client.post("/api/v1/agents", headers=auth(), json={
                "name": "researcher", "workspaceUuid": beta})).status_code == 201
            duplicate = await client.post("/api/v1/agents", headers=auth(), json={
                "name": "RESEARCHER", "workspaceUuid": alpha})
            assert duplicate.status_code == 400

            listed = lambda params="": client.get(f"/api/v1/agents{params}", headers=auth())  # noqa: E731
            assert [a["name"] for a in (await listed()).json()] == ["Helper", "Researcher", "researcher"]
            assert [a["name"] for a in (await listed(f"?workspaceUuid={alpha}")).json()] == [
                "Helper", "Researcher"]

            # Only the fields sent change; null clears one.
            changed = await client.put(f"/api/v1/agents/{agent['uuid']}", headers=auth(), json={
                "description": None, "enabled": False})
            assert changed.status_code == 200
            body = changed.json()
            assert body["description"] is None and body["enabled"] is False
            assert body["instructions"] == "Be thorough." and body["workspaceUuid"] == alpha
            moved = await client.put(f"/api/v1/agents/{agent['uuid']}", headers=auth(), json={
                "workspaceUuid": None})
            assert moved.json()["workspaceUuid"] is None
            clash = await client.put(f"/api/v1/agents/{wide['uuid']}", headers=auth(), json={
                "name": "researcher"})
            assert clash.status_code == 400
            assert (await client.put("/api/v1/agents/none", headers=auth(), json={"name": "Z"})).status_code == 404
            assert (await client.get("/api/v1/agents/none", headers=auth())).status_code == 404

            assert (await client.delete(f"/api/v1/agents/{wide['uuid']}", headers=auth())).status_code == 204
            assert (await client.delete(f"/api/v1/agents/{wide['uuid']}", headers=auth())).status_code == 404
            assert [t for t, _ in events if t.startswith("agent.")] == [
                "agent.created", "agent.created", "agent.created", "agent.updated", "agent.updated",
                "agent.deleted"]

            # Deleting a workspace removes its agents and keeps the account-wide ones.
            assert (await client.delete(f"/api/v1/workspaces/{beta}", headers=auth())).status_code == 204
            assert [a["name"] for a in (await listed()).json()] == ["Researcher"]
    run(scenario())


def test_agent_tools_manage_agents_and_force_approval(tmp_path):
    async def scenario():
        async with api_client(tmp_path) as (client, app):
            alpha = await _workspace(client)
            announced = []

            async def publish(event_type, data):
                announced.append(event_type)

            toolset = AgentTools(app.state.database, publish)
            tools = {t.name: t for t in toolset.tools(
                ApprovalConfig(create=False, read=False, update=False, delete=False),
                workspace_uuid=alpha)}
            assert sorted(tools) == ["create_agent", "delete_agent", "get_agent", "list_agents", "update_agent"]
            # Even with every approval switched off, changing agents asks; reading does not.
            assert {n: t.requires_approval for n, t in tools.items()} == {
                "list_agents": False, "get_agent": False,
                "create_agent": True, "update_agent": True, "delete_agent": True}
            assert toolset.tools(ApprovalConfig(), workspace_uuid=alpha, reserved={"create_agent"}) \
                and "create_agent" not in {t.name for t in toolset.tools(
                    ApprovalConfig(), workspace_uuid=alpha, reserved={"create_agent"})}

            made = await tools["create_agent"].function(
                name="Writer", description="Drafts text", instructions="Write well.",
                tools_config={"builtin_enabled": False}, approval_config={"read": False})
            assert made["ok"] is True and made["scope"] == "workspace"
            everywhere = await tools["create_agent"].function(name="Everywhere", scope="account")
            assert everywhere["scope"] == "account"
            assert (await tools["create_agent"].function(name="Writer"))["ok"] is False
            assert (await tools["create_agent"].function(name="Bad", scope="galaxy"))["ok"] is False
            assert (await tools["create_agent"].function(
                name="Bad", approval_config={"launch": True}))["ok"] is False

            summaries = await tools["list_agents"].function()
            assert [(s["name"], s["scope"]) for s in summaries] == [("Everywhere", "account"), ("Writer", "workspace")]
            detail = await tools["get_agent"].function("writer")
            assert detail["instructions"] == "Write well."
            assert detail["toolsConfig"] == {"builtin_enabled": False}
            assert detail["approvalConfig"] == {"read": False}
            assert (await tools["get_agent"].function("nobody"))["ok"] is False

            assert (await tools["update_agent"].function("Writer"))["ok"] is False  # nothing to change
            renamed = await tools["update_agent"].function(
                "Writer", new_name="Author", enabled=False, scope="account", inherit_tools=True)
            assert renamed == {"ok": True, "id": made["id"], "name": "Author"}
            detail = await tools["get_agent"].function(made["id"])
            assert detail["scope"] == "account" and detail["enabled"] is False
            assert detail["toolsConfig"] is None and detail["approvalConfig"] == {"read": False}

            assert (await tools["delete_agent"].function("Author")) == {"ok": True, "removed": "Author"}
            assert (await tools["delete_agent"].function("Author"))["ok"] is False
            assert announced == ["agent.created", "agent.created", "agent.updated", "agent.deleted"]
    run(scenario())
