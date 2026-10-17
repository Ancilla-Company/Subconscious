CREATE TABLE contacts (
	id INTEGER NOT NULL, 
	workspace_id INTEGER NOT NULL, 
	name VARCHAR NOT NULL, 
	email VARCHAR, 
	phone VARCHAR, 
	notes TEXT, 
	created_at DATETIME, 
	updated_at DATETIME, uuid TEXT, 
	PRIMARY KEY (id), 
	FOREIGN KEY(workspace_id) REFERENCES workspaces (id)
);
CREATE TABLE document_chunks (
	id INTEGER NOT NULL, 
	document_id INTEGER NOT NULL, 
	workspace_id INTEGER NOT NULL, 
	ordinal INTEGER NOT NULL, 
	content TEXT NOT NULL, 
	start_line INTEGER, 
	end_line INTEGER, 
	token_estimate INTEGER, 
	embedding TEXT, 
	created_at DATETIME, 
	PRIMARY KEY (id), 
	FOREIGN KEY(document_id) REFERENCES indexed_documents (id), 
	FOREIGN KEY(workspace_id) REFERENCES workspaces (id)
);
CREATE TABLE hive_meta (
	"key" VARCHAR NOT NULL, 
	value TEXT NOT NULL, 
	PRIMARY KEY ("key")
);
CREATE TABLE indexed_documents (
	id INTEGER NOT NULL, 
	workspace_id INTEGER NOT NULL, 
	path VARCHAR NOT NULL, 
	directory VARCHAR, 
	size INTEGER, 
	mtime INTEGER, 
	content_hash VARCHAR, 
	chunk_count INTEGER NOT NULL, 
	status VARCHAR NOT NULL, 
	error TEXT, 
	indexed_at DATETIME, 
	PRIMARY KEY (id), 
	FOREIGN KEY(workspace_id) REFERENCES workspaces (id)
);
CREATE TABLE messages (
	id INTEGER NOT NULL, 
	thread_id INTEGER NOT NULL, 
	role VARCHAR NOT NULL, 
	content TEXT NOT NULL, 
	created_at DATETIME, uuid VARCHAR, origin_node_id TEXT, hlc TEXT, deleted_at DATETIME, 
	PRIMARY KEY (id), 
	FOREIGN KEY(thread_id) REFERENCES threads (id)
);
CREATE TABLE networks (
	id INTEGER NOT NULL, 
	uuid VARCHAR, 
	name VARCHAR NOT NULL, 
	description TEXT, 
	default_workspace_uuid VARCHAR, 
	passphrase BLOB, 
	created_at DATETIME, 
	PRIMARY KEY (id), 
	UNIQUE (uuid)
);
CREATE TABLE notes (
	id INTEGER NOT NULL, 
	workspace_id INTEGER NOT NULL, 
	title VARCHAR NOT NULL, 
	content TEXT NOT NULL, 
	tags VARCHAR, 
	created_at DATETIME, 
	updated_at DATETIME, uuid TEXT, 
	PRIMARY KEY (id), 
	FOREIGN KEY(workspace_id) REFERENCES workspaces (id)
);
CREATE TABLE remote_tool_audit (
	id INTEGER NOT NULL, 
	ts DATETIME NOT NULL, 
	direction VARCHAR NOT NULL, 
	peer_node_id VARCHAR NOT NULL, 
	task_id VARCHAR, 
	tool VARCHAR NOT NULL, 
	args_sha256 VARCHAR NOT NULL, 
	outcome VARCHAR NOT NULL, 
	duration_ms INTEGER NOT NULL, 
	PRIMARY KEY (id), 
	CONSTRAINT ck_remote_tool_audit_direction CHECK (direction IN ('in', 'out'))
);
CREATE TABLE skill_registry (
	id INTEGER NOT NULL, 
	uuid VARCHAR, 
	name VARCHAR NOT NULL, 
	alias VARCHAR, 
	description TEXT, 
	source VARCHAR NOT NULL, 
	source_type VARCHAR NOT NULL, 
	install_path VARCHAR, 
	version VARCHAR, 
	status VARCHAR NOT NULL, 
	required_tools TEXT, 
	metadata_json TEXT, 
	created_at DATETIME, 
	updated_at DATETIME, 
	PRIMARY KEY (id), 
	UNIQUE (uuid)
);
CREATE TABLE sync_field_clock (
	entity VARCHAR NOT NULL, 
	entity_uuid VARCHAR NOT NULL, 
	field VARCHAR NOT NULL, 
	hlc VARCHAR NOT NULL, 
	origin_node_id VARCHAR NOT NULL, 
	PRIMARY KEY (entity, entity_uuid, field)
);
CREATE TABLE sync_log (
	origin_node_id VARCHAR NOT NULL, 
	origin_seq INTEGER NOT NULL, 
	entity VARCHAR NOT NULL, 
	entity_uuid VARCHAR NOT NULL, 
	op VARCHAR NOT NULL, 
	hlc VARCHAR NOT NULL, 
	payload TEXT NOT NULL, 
	sig VARCHAR NOT NULL, 
	PRIMARY KEY (origin_node_id, origin_seq)
);
CREATE TABLE sync_pending (
	id INTEGER NOT NULL, 
	origin_node_id VARCHAR NOT NULL, 
	origin_seq INTEGER NOT NULL, 
	missing_entity VARCHAR NOT NULL, 
	missing_uuid VARCHAR NOT NULL, 
	op TEXT NOT NULL, 
	PRIMARY KEY (id), 
	CONSTRAINT uq_sync_pending_op UNIQUE (origin_node_id, origin_seq)
);
CREATE TABLE sync_state (
	id INTEGER NOT NULL, 
	hive_id VARCHAR, 
	node_id VARCHAR, 
	last_hlc VARCHAR, 
	per_origin_applied TEXT NOT NULL, 
	local_seq INTEGER NOT NULL, 
	PRIMARY KEY (id)
);
CREATE TABLE tasks (
	id INTEGER NOT NULL, 
	task_id VARCHAR NOT NULL, 
	thread_uuid VARCHAR NOT NULL, 
	workspace_uuid VARCHAR, 
	executor_node_id VARCHAR NOT NULL, 
	requester_node_id VARCHAR NOT NULL, 
	status VARCHAR NOT NULL, 
	rev INTEGER NOT NULL, 
	turn_id VARCHAR, 
	model_id VARCHAR, 
	client_msg_uuid VARCHAR, 
	created_at DATETIME NOT NULL, 
	started_at DATETIME, 
	finished_at DATETIME, 
	error TEXT, 
	payload TEXT, 
	origin_node_id VARCHAR, 
	hlc VARCHAR, 
	deleted_at DATETIME, 
	PRIMARY KEY (id), 
	UNIQUE (task_id)
);
CREATE TABLE threads (
	id INTEGER NOT NULL, 
	workspace_id INTEGER NOT NULL, 
	title VARCHAR, 
	description VARCHAR, 
	updated_at DATETIME, 
	created_at DATETIME, default_model_id VARCHAR, tools_config TEXT, skills_config TEXT, uuid VARCHAR, approval_config TEXT, origin_node_id TEXT, hlc TEXT, deleted_at DATETIME, 
	PRIMARY KEY (id), 
	FOREIGN KEY(workspace_id) REFERENCES workspaces (id)
);
CREATE TABLE todo_items (
	id INTEGER NOT NULL, 
	workspace_id INTEGER NOT NULL, 
	thread_id INTEGER, 
	title VARCHAR NOT NULL, 
	notes TEXT, 
	status VARCHAR NOT NULL, 
	priority VARCHAR NOT NULL, 
	due_date DATETIME, 
	created_at DATETIME, 
	updated_at DATETIME, uuid TEXT, 
	PRIMARY KEY (id), 
	FOREIGN KEY(workspace_id) REFERENCES workspaces (id), 
	FOREIGN KEY(thread_id) REFERENCES threads (id)
);
CREATE TABLE tool_registry (
	id INTEGER NOT NULL, 
	uuid VARCHAR, 
	name VARCHAR NOT NULL, 
	alias VARCHAR, 
	description TEXT, 
	tool_type VARCHAR NOT NULL, 
	script_path VARCHAR, 
	script_language VARCHAR, 
	endpoint_url VARCHAR, 
	auth_type VARCHAR, 
	auth_env_var VARCHAR, 
	status VARCHAR NOT NULL, 
	created_at DATETIME, 
	updated_at DATETIME, 
	PRIMARY KEY (id), 
	UNIQUE (uuid)
);
CREATE TABLE workspace_memory (
	id INTEGER NOT NULL, 
	workspace_id INTEGER NOT NULL, 
	"key" VARCHAR NOT NULL, 
	value TEXT NOT NULL, 
	source_thread_id INTEGER, 
	created_at DATETIME, 
	updated_at DATETIME, uuid TEXT, 
	PRIMARY KEY (id), 
	FOREIGN KEY(workspace_id) REFERENCES workspaces (id), 
	FOREIGN KEY(source_thread_id) REFERENCES threads (id)
);
CREATE TABLE workspaces (
	id INTEGER NOT NULL, 
	name VARCHAR NOT NULL, 
	description VARCHAR, 
	network_id INTEGER NOT NULL, 
	uuid VARCHAR, 
	updated_at DATETIME, 
	created_at DATETIME, tools_config TEXT, skills_config TEXT, directories TEXT, approval_config TEXT, "default_model_id" TEXT NULL, "rag_config" TEXT NULL, origin_node_id TEXT, hlc TEXT, deleted_at DATETIME, 
	PRIMARY KEY (id), 
	FOREIGN KEY(network_id) REFERENCES networks (id)
);
CREATE UNIQUE INDEX ix_contacts_uuid ON "contacts" (uuid);
CREATE INDEX ix_document_chunks_document_id ON document_chunks (document_id);
CREATE INDEX ix_document_chunks_workspace_id ON document_chunks (workspace_id);
CREATE INDEX ix_indexed_documents_path ON indexed_documents (path);
CREATE INDEX ix_indexed_documents_workspace_id ON indexed_documents (workspace_id);
CREATE UNIQUE INDEX ix_notes_uuid ON "notes" (uuid);
CREATE INDEX ix_remote_tool_audit_ts ON remote_tool_audit (ts);
CREATE INDEX ix_sync_log_entity ON sync_log (entity, entity_uuid);
CREATE INDEX ix_sync_pending_missing_uuid ON sync_pending (missing_uuid);
CREATE INDEX ix_tasks_thread_uuid ON tasks (thread_uuid);
CREATE UNIQUE INDEX ix_todo_items_uuid ON "todo_items" (uuid);
CREATE UNIQUE INDEX ix_workspace_memory_uuid ON "workspace_memory" (uuid);
CREATE TRIGGER remote_tool_audit_no_delete BEFORE DELETE ON remote_tool_audit BEGIN SELECT RAISE(ABORT, 'remote_tool_audit is append-only'); END;
CREATE TRIGGER remote_tool_audit_no_update BEFORE UPDATE ON remote_tool_audit BEGIN SELECT RAISE(ABORT, 'remote_tool_audit is append-only'); END;