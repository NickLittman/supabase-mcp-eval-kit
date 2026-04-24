-- ============================================================================
-- Supabase MCP Eval Sandbox
-- A pre-populated project management schema for testing MCP tool calls
-- across the full Supabase surface area.
--
-- SETUP INSTRUCTIONS:
-- Option A (one command): ./setup.sh --org-id <org-id>
-- Option B (manual):
--   1. Create a fresh Supabase project (via dashboard or MCP create_project)
--   2. Paste this script into the SQL Editor, or use the CLI:
--        supabase link --project-ref <ref> && supabase db push
--   3. Deploy the Edge Function:
--        supabase functions deploy team-stats --project-ref <ref>
--      (see supabase/functions/team-stats/index.ts)
--
-- MCP TOOL COVERAGE:
--   execute_sql          — DML queries, JOINs, filters, aggregations, JSONB, vector
--   apply_migration      — this script itself is a migration target
--   list_tables          — 8 tables + 1 view, compact and verbose modes
--   list_extensions      — pgvector enabled for semantic search
--   list_migrations      — migration history after apply_migration
--   generate_typescript  — enums, JSONB, nullable, vector, view types
--   get_advisors         — security (RLS on all tables), performance (indexes)
--   deploy_edge_function — team-stats function
--   get_edge_function    — retrieve deployed function source
--   list_edge_functions  — see function in list
--   get_logs             — postgres + edge-function logs after activity
--   get_project_url      — API URL for client connections
--   get_publishable_keys — anon key for auth testing
--   search_docs          — reference when agents need help with patterns
-- ============================================================================

-- ============================================================================
-- SECTION 1: Extensions
-- Tests: list_extensions — should show pgvector as enabled (non-default)
-- ============================================================================

create extension if not exists vector
  with schema extensions;

-- ============================================================================
-- SECTION 2: Custom Enum Types
-- Tests: generate_typescript_types — enum types map to TS string unions
-- ============================================================================

create type member_role as enum ('owner', 'admin', 'member');
create type project_status as enum ('active', 'archived', 'on_hold');
create type task_status as enum ('todo', 'in_progress', 'in_review', 'done');
create type task_priority as enum ('low', 'medium', 'high', 'urgent');

-- ============================================================================
-- SECTION 3: Schemas
-- Tests: Security definer functions must NOT live in exposed schemas (public).
--        Per Supabase docs, we use a private schema for RLS helper functions.
-- ============================================================================

create schema if not exists private;

-- ============================================================================
-- SECTION 4: Tables
-- Tests: list_tables (compact) — should return 8 tables
--        list_tables (verbose) — columns, PKs, FKs, constraints visible
--        generate_typescript_types — diverse column types (uuid, text,
--          timestamptz, enum, jsonb, bigint, vector, nullable)
--        get_advisors (performance) — all FK columns have indexes
-- ============================================================================

-- 4a: teams
create table teams (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  slug       text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint teams_slug_format check (slug ~ '^[a-z0-9][a-z0-9-]*[a-z0-9]$')
);

comment on table teams is 'Top-level organizational unit. Every row in the app is scoped to a team.';

-- 4b: members — maps auth.users to teams with a role
create table members (
  id           uuid primary key default gen_random_uuid(),
  team_id      uuid not null references teams(id) on delete cascade,
  user_id      uuid not null,  -- references auth.users(id) logically
  role         member_role not null default 'member',
  email        text not null,
  display_name text not null,
  joined_at    timestamptz not null default now(),

  constraint members_unique_per_team unique (team_id, user_id)
);

create index members_team_id_idx on members(team_id);
create index members_user_id_idx on members(user_id);
create index members_user_team_idx on members(user_id, team_id);

comment on table members is 'Join table between auth.users and teams. Central to all RLS policies.';

-- 4c: projects
create table projects (
  id          uuid primary key default gen_random_uuid(),
  team_id     uuid not null references teams(id) on delete cascade,
  name        text not null,
  description text,
  status      project_status not null default 'active',
  created_by  uuid references members(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index projects_team_id_idx on projects(team_id);
create index projects_created_by_idx on projects(created_by);
create index projects_status_idx on projects(status);

-- 4d: tasks — the most complex table, exercises many column types
create table tasks (
  id          uuid primary key default gen_random_uuid(),
  project_id  uuid not null references projects(id) on delete cascade,
  title       text not null,
  description text,
  status      task_status not null default 'todo',
  priority    task_priority not null default 'medium',
  assignee_id uuid references members(id) on delete set null,
  reporter_id uuid references members(id) on delete set null,
  due_date    date,
  metadata    jsonb default '{}',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
  -- Note: no CHECK on due_date vs created_at because seed data intentionally
  -- includes overdue tasks (due_date in the past) for eval coverage.
);

create index tasks_project_id_idx on tasks(project_id);
create index tasks_assignee_id_idx on tasks(assignee_id);
create index tasks_reporter_id_idx on tasks(reporter_id);
create index tasks_status_idx on tasks(status);
create index tasks_assignee_status_idx on tasks(assignee_id, status);
create index tasks_metadata_gin_idx on tasks using gin(metadata);
-- Tests: execute_sql with JSONB operators (@>, ->>, ->) against this GIN index

-- 4e: documents — metadata for files stored in Supabase Storage
create table documents (
  id                uuid primary key default gen_random_uuid(),
  project_id        uuid not null references projects(id) on delete cascade,
  title             text not null,
  file_path         text not null,  -- path within storage bucket
  file_size_bytes   bigint not null,
  mime_type         text not null,
  uploaded_by       uuid not null references members(id) on delete cascade,
  -- Note: no FK to storage.objects — Supabase docs say treat the storage schema
  -- as read-only. App-level metadata lives here; file-level metadata lives in
  -- storage.objects. Correlated by file_path matching the storage object name.
  created_at        timestamptz not null default now(),

  constraint documents_file_size_positive check (file_size_bytes > 0)
);

create index documents_project_id_idx on documents(project_id);
create index documents_uploaded_by_idx on documents(uploaded_by);

-- 4f: comments — supports threading via self-referential FK
create table comments (
  id         uuid primary key default gen_random_uuid(),
  task_id    uuid not null references tasks(id) on delete cascade,
  author_id  uuid not null references members(id) on delete cascade,
  body       text not null,
  parent_id  uuid references comments(id) on delete cascade,  -- self-ref for threading
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index comments_task_id_idx on comments(task_id);
create index comments_author_id_idx on comments(author_id);
create index comments_parent_id_idx on comments(parent_id);

comment on table comments is 'Threaded comments on tasks. Self-referential FK tests recursive queries.';

-- 4g: audit_log — populated by trigger, not direct inserts
create table audit_log (
  id         bigserial primary key,
  table_name text not null,
  record_id  uuid not null,
  action     text not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  old_data   jsonb,
  new_data   jsonb,
  changed_by uuid,  -- auth.uid() at time of change
  changed_at timestamptz not null default now()
);

create index audit_log_table_record_idx on audit_log(table_name, record_id);
create index audit_log_changed_at_idx on audit_log(changed_at);

comment on table audit_log is 'Append-only log populated by triggers. Tests trigger verification and JSONB querying.';

-- 4h: task_embeddings — pgvector for semantic search
-- Tests: list_extensions (pgvector), execute_sql with vector operators (<=>),
--        generate_typescript_types with vector column type,
--        HNSW index for approximate nearest neighbor search
create table task_embeddings (
  id         uuid primary key default gen_random_uuid(),
  task_id    uuid not null references tasks(id) on delete cascade unique,
  embedding  extensions.vector(384) not null,  -- 384 dims = all-MiniLM-L6-v2
  model      text not null default 'all-MiniLM-L6-v2',
  created_at timestamptz not null default now()
);

create index task_embeddings_task_id_idx on task_embeddings(task_id);
-- Operator classes cannot be schema-qualified in CREATE INDEX.
-- The extensions schema is on search_path by default on Supabase.
create index task_embeddings_hnsw_idx on task_embeddings
  using hnsw (embedding vector_cosine_ops);

comment on table task_embeddings is 'Vector embeddings for semantic task search. Tests pgvector extension and HNSW indexes.';

-- ============================================================================
-- SECTION 5: Row-Level Security — Enable + Helper Functions
-- Tests: get_advisors (security) — all tables should report RLS enabled
--        execute_sql — queries return different results per authenticated user
--        RLS with (select auth.uid()) — cached subquery pattern (not per-row)
-- ============================================================================

alter table teams enable row level security;
alter table members enable row level security;
alter table projects enable row level security;
alter table tasks enable row level security;
alter table documents enable row level security;
alter table comments enable row level security;
alter table audit_log enable row level security;
alter table task_embeddings enable row level security;

-- Helper: get the team IDs the current user belongs to
-- Lives in `private` schema — security definer functions must NOT be in exposed schemas
-- per Supabase RLS performance docs.
create or replace function private.get_my_team_ids()
returns setof uuid
language sql
security definer
set search_path = ''
stable
as $$
  select team_id
  from public.members
  where user_id = (select auth.uid());
$$;

-- Helper: get the current user's role in a specific team
create or replace function private.get_my_role(p_team_id uuid)
returns member_role
language sql
security definer
set search_path = ''
stable
as $$
  select role
  from public.members
  where user_id = (select auth.uid())
    and team_id = p_team_id
  limit 1;
$$;

-- Helper: check if current user is a member of a team
create or replace function private.is_team_member(p_team_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1
    from public.members
    where user_id = (select auth.uid())
      and team_id = p_team_id
  );
$$;

-- ============================================================================
-- SECTION 6: RLS Policies
-- Tests: execute_sql returns filtered results based on auth context
--        Multi-hop RLS — comments → tasks → projects → teams → members
--        Agents must understand empty result sets under RLS
--        All policies use:
--          - (select auth.uid()) for caching (not called per-row)
--          - TO authenticated to skip policy evaluation for anon role
--          - private.* helper functions (security definer, not in public schema)
-- ============================================================================

-- 6a: teams policies
-- Tests: RLS filtering when authenticated as different users
create policy "teams: members can view their teams"
  on teams for select
  to authenticated
  using (id in (select private.get_my_team_ids()));

create policy "teams: owner/admin can update"
  on teams for update
  to authenticated
  using ((select private.get_my_role(id)) in ('owner', 'admin'));

-- 6b: members policies
-- Tests: RLS on the table that powers RLS helpers (bootstrap problem —
--        helpers use security definer to bypass this circular dependency)
create policy "members: can view teammates"
  on members for select
  to authenticated
  using (team_id in (select private.get_my_team_ids()));

create policy "members: owner can insert"
  on members for insert
  to authenticated
  with check ((select private.get_my_role(team_id)) = 'owner');

create policy "members: owner can update"
  on members for update
  to authenticated
  using ((select private.get_my_role(team_id)) = 'owner');

create policy "members: owner can delete"
  on members for delete
  to authenticated
  using ((select private.get_my_role(team_id)) = 'owner');

-- 6c: projects policies
-- Tests: execute_sql with JOIN filtered by team membership
create policy "projects: team members can view"
  on projects for select
  to authenticated
  using (team_id in (select private.get_my_team_ids()));

create policy "projects: admin/owner can insert"
  on projects for insert
  to authenticated
  with check ((select private.get_my_role(team_id)) in ('owner', 'admin'));

create policy "projects: admin/owner can update"
  on projects for update
  to authenticated
  using ((select private.get_my_role(team_id)) in ('owner', 'admin'));

create policy "projects: owner can delete"
  on projects for delete
  to authenticated
  using ((select private.get_my_role(team_id)) = 'owner');

-- 6d: tasks policies
-- Tests: multi-hop RLS — task → project → team → member check
--        execute_sql with UPDATE restricted to assignee or admin
--        service_role bypass via auth.jwt() claim extraction
create policy "tasks: team members can view via project"
  on tasks for select
  to authenticated
  using (
    exists (
      select 1 from projects p
      where p.id = tasks.project_id
        and p.team_id in (select private.get_my_team_ids())
    )
  );

create policy "tasks: team members can insert"
  on tasks for insert
  to authenticated
  with check (
    exists (
      select 1 from projects p
      where p.id = tasks.project_id
        and p.team_id in (select private.get_my_team_ids())
    )
  );

create policy "tasks: assignee or admin can update"
  on tasks for update
  to authenticated
  using (
    assignee_id in (
      select m.id from members m where m.user_id = (select auth.uid())
    )
    or exists (
      select 1 from projects p
      where p.id = tasks.project_id
        and (select private.get_my_role(p.team_id)) in ('owner', 'admin')
    )
  );

create policy "tasks: admin/owner can delete"
  on tasks for delete
  to authenticated
  using (
    exists (
      select 1 from projects p
      where p.id = tasks.project_id
        and (select private.get_my_role(p.team_id)) in ('owner', 'admin')
    )
  );

-- Tests: auth.jwt() claim extraction — agents often confuse auth.uid() vs auth.jwt()
-- NOTE: On Supabase, service_role already has BYPASSRLS at the Postgres level,
-- so this policy is never actually evaluated for service_role requests. It exists
-- purely to test that MCP agents can introspect policies using the auth.jwt()
-- pattern, which is common in real-world apps for custom role checks.
create policy "tasks: service_role bypass"
  on tasks for all
  using ((select auth.jwt()->>'role') = 'service_role');

-- 6e: documents policies
-- Tests: RLS scoped through project → team chain
create policy "documents: team members can view"
  on documents for select
  to authenticated
  using (
    exists (
      select 1 from projects p
      where p.id = documents.project_id
        and p.team_id in (select private.get_my_team_ids())
    )
  );

create policy "documents: team members can insert"
  on documents for insert
  to authenticated
  with check (
    exists (
      select 1 from projects p
      where p.id = documents.project_id
        and p.team_id in (select private.get_my_team_ids())
    )
  );

create policy "documents: uploader or admin can update"
  on documents for update
  to authenticated
  using (
    uploaded_by in (
      select m.id from members m where m.user_id = (select auth.uid())
    )
    or exists (
      select 1 from projects p
      where p.id = documents.project_id
        and (select private.get_my_role(p.team_id)) in ('owner', 'admin')
    )
  );

create policy "documents: uploader or admin can delete"
  on documents for delete
  to authenticated
  using (
    uploaded_by in (
      select m.id from members m where m.user_id = (select auth.uid())
    )
    or exists (
      select 1 from projects p
      where p.id = documents.project_id
        and (select private.get_my_role(p.team_id)) in ('owner', 'admin')
    )
  );

-- 6f: comments policies
-- Tests: deepest multi-hop — comment → task → project → team → member
--        Author-only update (agents often get this wrong)
create policy "comments: team members can view"
  on comments for select
  to authenticated
  using (
    exists (
      select 1 from tasks t
      join projects p on p.id = t.project_id
      where t.id = comments.task_id
        and p.team_id in (select private.get_my_team_ids())
    )
  );

create policy "comments: team members can insert"
  on comments for insert
  to authenticated
  with check (
    exists (
      select 1 from tasks t
      join projects p on p.id = t.project_id
      where t.id = comments.task_id
        and p.team_id in (select private.get_my_team_ids())
    )
  );

create policy "comments: author can update own"
  on comments for update
  to authenticated
  using (
    author_id in (
      select m.id from members m where m.user_id = (select auth.uid())
    )
  );

create policy "comments: author or admin can delete"
  on comments for delete
  to authenticated
  using (
    author_id in (
      select m.id from members m where m.user_id = (select auth.uid())
    )
    or exists (
      select 1 from tasks t
      join projects p on p.id = t.project_id
      where t.id = comments.task_id
        and (select private.get_my_role(p.team_id)) in ('owner', 'admin')
    )
  );

-- 6g: audit_log policies
-- Tests: read-only table — no INSERT/UPDATE/DELETE policies (trigger bypasses RLS)
create policy "audit_log: admin/owner can view team entries"
  on audit_log for select
  to authenticated
  using (
    exists (
      select 1 from tasks t
      join projects p on p.id = t.project_id
      where t.id = audit_log.record_id
        and (select private.get_my_role(p.team_id)) in ('owner', 'admin')
    )
  );

-- 6h: task_embeddings policies
-- Tests: RLS on vector table — scoped through task → project → team chain
create policy "task_embeddings: team members can view"
  on task_embeddings for select
  to authenticated
  using (
    exists (
      select 1 from tasks t
      join projects p on p.id = t.project_id
      where t.id = task_embeddings.task_id
        and p.team_id in (select private.get_my_team_ids())
    )
  );

-- ============================================================================
-- SECTION 7: Storage Bucket + Policies
-- Tests: Storage bucket creation via SQL (insert into storage.buckets)
--        Storage RLS — upload/download scoped to team membership
--        Agents often confuse storage.objects policies with table policies
--        Uses owner_id column and TO authenticated per Supabase docs
-- ============================================================================

insert into storage.buckets (id, name, public)
values ('documents', 'documents', false)
on conflict (id) do nothing;

-- Storage: team members can read files in their team's folder
create policy "storage: team members can download"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'documents'
    and (storage.foldername(name))[1] in (
      select id::text from teams where id in (select private.get_my_team_ids())
    )
  );

-- Storage: team members can upload to their team's folder
create policy "storage: team members can upload"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'documents'
    and (storage.foldername(name))[1] in (
      select id::text from teams where id in (select private.get_my_team_ids())
    )
  );

-- Storage: only the uploader can update their own files
create policy "storage: uploader can update"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'documents'
    and (select auth.uid())::text = owner_id
  );

-- Storage: uploader or team admin can delete
create policy "storage: uploader or admin can delete"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'documents'
    and (
      (select auth.uid())::text = owner_id
      or (storage.foldername(name))[1] in (
        select t.id::text from teams t
        where (select private.get_my_role(t.id)) in ('owner', 'admin')
      )
    )
  );

-- ============================================================================
-- SECTION 8: Realtime Publication
-- Tests: Realtime subscriptions on tasks and comments
--        Agents must know which tables support realtime
-- ============================================================================

alter publication supabase_realtime add table tasks;
alter publication supabase_realtime add table comments;

-- ============================================================================
-- SECTION 9: Trigger Function + Trigger
-- Tests: Trigger fires on INSERT/UPDATE/DELETE of tasks
--        audit_log auto-populates — verify with execute_sql after DML
--        JSONB diff between old_data and new_data
-- ============================================================================

create or replace function private.fn_audit_log()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.audit_log (table_name, record_id, action, old_data, new_data, changed_by)
  values (
    TG_TABLE_NAME,
    coalesce(NEW.id, OLD.id),
    TG_OP,
    case when TG_OP in ('UPDATE', 'DELETE') then to_jsonb(OLD) else null end,
    case when TG_OP in ('INSERT', 'UPDATE') then to_jsonb(NEW) else null end,
    auth.uid()
  );
  return coalesce(NEW, OLD);
end;
$$;

create trigger tasks_audit_trigger
  after insert or update or delete on tasks
  for each row execute function private.fn_audit_log();

-- ============================================================================
-- SECTION 10: RPC Functions (callable via execute_sql)
-- Tests: execute_sql("select * from get_team_dashboard('...')")
--        execute_sql("select * from search_tasks('query', '...')")
--        execute_sql("select * from match_tasks('[0.1,...]'::vector, 0.5, 5)")
--        Function return types in generate_typescript_types
-- ============================================================================

-- 10a: Team dashboard — returns JSON aggregate with task stats
-- Tests: execute_sql with function call returning JSON
create or replace function get_team_dashboard(p_team_id uuid)
returns json
language sql
security definer
set search_path = ''
stable
as $$
  select json_build_object(
    'team_id', p_team_id,
    'member_count', (
      select count(*) from public.members where team_id = p_team_id
    ),
    'task_counts', (
      select json_object_agg(status, cnt)
      from (
        select t.status, count(*) as cnt
        from public.tasks t
        join public.projects p on p.id = t.project_id
        where p.team_id = p_team_id
        group by t.status
      ) sub
    ),
    'overdue_count', (
      select count(*)
      from public.tasks t
      join public.projects p on p.id = t.project_id
      where p.team_id = p_team_id
        and t.due_date < current_date
        and t.status not in ('done')
    ),
    'recent_activity', (
      select json_agg(row_to_json(sub))
      from (
        select a.action, a.changed_at, a.record_id
        from public.audit_log a
        join public.tasks t on t.id = a.record_id
        join public.projects p on p.id = t.project_id
        where a.table_name = 'tasks'
          and p.team_id = p_team_id
        order by a.changed_at desc
        limit 5
      ) sub
    )
  );
$$;

comment on function get_team_dashboard is 'RPC function returning a JSON dashboard summary for a team. Tests execute_sql with function calls.';

-- 10b: Text search using ILIKE
-- Tests: execute_sql with table-returning function, text search
create or replace function search_tasks(p_query text, p_team_id uuid)
returns table (
  id uuid,
  title text,
  status task_status,
  priority task_priority,
  project_name text,
  assignee_name text
)
language sql
security definer
set search_path = ''
stable
as $$
  select
    t.id,
    t.title,
    t.status,
    t.priority,
    p.name as project_name,
    m.display_name as assignee_name
  from public.tasks t
  join public.projects p on p.id = t.project_id
  left join public.members m on m.id = t.assignee_id
  where p.team_id = p_team_id
    and (
      t.title ilike '%' || p_query || '%'
      or t.description ilike '%' || p_query || '%'
    )
  order by t.created_at desc
  limit 20;
$$;

comment on function search_tasks is 'Text search over tasks using ILIKE. Tests table-returning RPC functions.';

-- 10c: Semantic search using pgvector — follows the Supabase match_documents pattern
-- Tests: execute_sql with vector operators (<=>), pgvector extension usage,
--        HNSW index utilization (order by must use distance operator directly)
create or replace function match_tasks(
  query_embedding extensions.vector(384),
  match_threshold float,
  match_count int
)
returns table (
  id uuid,
  title text,
  status task_status,
  project_name text,
  similarity float
)
language sql
security definer
set search_path = 'public', 'extensions'
stable
as $$
  select
    t.id,
    t.title,
    t.status,
    p.name as project_name,
    1 - (te.embedding <=> query_embedding) as similarity
  from public.task_embeddings te
  join public.tasks t on t.id = te.task_id
  join public.projects p on p.id = t.project_id
  where 1 - (te.embedding <=> query_embedding) > match_threshold
  order by te.embedding <=> query_embedding  -- must use operator directly for index
  limit match_count;
$$;

comment on function match_tasks is 'Semantic search over task embeddings using pgvector cosine distance. Follows the Supabase match_documents pattern.';

-- ============================================================================
-- SECTION 11: View
-- Tests: list_tables — views may or may not appear (common MCP confusion)
--        execute_sql("select * from task_details") — querying a view
--        generate_typescript_types — view type inference
--        security_invoker = true — view respects calling user's RLS (Postgres 15+)
-- ============================================================================

create or replace view task_details
  with (security_invoker = true)
as
select
  t.id as task_id,
  t.title,
  t.description,
  t.status as task_status,
  t.priority,
  t.due_date,
  t.metadata,
  t.created_at as task_created_at,
  t.updated_at as task_updated_at,
  p.id as project_id,
  p.name as project_name,
  p.status as project_status,
  tm.id as team_id,
  tm.name as team_name,
  tm.slug as team_slug,
  assignee.id as assignee_id,
  assignee.display_name as assignee_name,
  assignee.email as assignee_email,
  reporter.id as reporter_id,
  reporter.display_name as reporter_name
from tasks t
join projects p on p.id = t.project_id
join teams tm on tm.id = p.team_id
left join members assignee on assignee.id = t.assignee_id
left join members reporter on reporter.id = t.reporter_id;

comment on view task_details is 'Denormalized view joining tasks, projects, teams, and members. Uses security_invoker so RLS is respected per calling user.';

-- ============================================================================
-- SECTION 12: Seed Data
-- Tests: execute_sql SELECT — basic data retrieval on populated tables
--        execute_sql with filters — WHERE on enums, dates, JSONB
--        execute_sql with aggregation — GROUP BY, COUNT across seed data
--        execute_sql with pagination — LIMIT/OFFSET on 18 tasks
--        Trigger verification — audit_log auto-populated from task inserts
--        Auth user seeding — RLS is testable end-to-end with real JWTs
-- ============================================================================

do $$
declare
  -- Teams
  team_eng  uuid := gen_random_uuid();
  team_prod uuid := gen_random_uuid();
  team_dsgn uuid := gen_random_uuid();

  -- Members — Engineering (3)
  m_alice   uuid := gen_random_uuid();  -- eng owner
  m_bob     uuid := gen_random_uuid();  -- eng admin
  m_carol   uuid := gen_random_uuid();  -- eng member

  -- Members — Product (3)
  m_dave    uuid := gen_random_uuid();  -- product owner
  m_eve     uuid := gen_random_uuid();  -- product admin
  m_frank   uuid := gen_random_uuid();  -- product member

  -- Members — Design (3)
  m_grace   uuid := gen_random_uuid();  -- design owner
  m_heidi   uuid := gen_random_uuid();  -- design admin
  m_ivan    uuid := gen_random_uuid();  -- design member

  -- Auth user IDs (same UUIDs used in both auth.users and members.user_id)
  u_alice   uuid := gen_random_uuid();
  u_bob     uuid := gen_random_uuid();
  u_carol   uuid := gen_random_uuid();
  u_dave    uuid := gen_random_uuid();
  u_eve     uuid := gen_random_uuid();
  u_frank   uuid := gen_random_uuid();
  u_grace   uuid := gen_random_uuid();
  u_heidi   uuid := gen_random_uuid();
  u_ivan    uuid := gen_random_uuid();

  -- Projects
  p_api     uuid := gen_random_uuid();
  p_mobile  uuid := gen_random_uuid();
  p_launch  uuid := gen_random_uuid();
  p_rebrand uuid := gen_random_uuid();
  p_archive uuid := gen_random_uuid();

  -- Tasks (declare a few we need to reference for comments)
  t1 uuid := gen_random_uuid();
  t2 uuid := gen_random_uuid();
  t3 uuid := gen_random_uuid();
  t4 uuid := gen_random_uuid();
  t5 uuid := gen_random_uuid();

  -- Comments (need one ID for threading)
  c1 uuid := gen_random_uuid();
begin

  -- ---- Auth Users (into auth.users so RLS works end-to-end) ----
  -- Tests: RLS policies can be verified by generating JWTs for these users
  --        via supabase.auth.admin.generateLink() or direct token creation.
  --        Each user has raw_user_meta_data (user-modifiable display info)
  --        and raw_app_meta_data (provider info, not user-modifiable).
  insert into auth.users (
    id, instance_id, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data,
    role, aud, created_at, updated_at
  ) values
    (u_alice, '00000000-0000-0000-0000-000000000000', 'alice@example.com',
     crypt('password123', gen_salt('bf')), now(),
     '{"provider": "email", "providers": ["email"]}'::jsonb,
     '{"display_name": "Alice Chen"}'::jsonb,
     'authenticated', 'authenticated', now(), now()),
    (u_bob, '00000000-0000-0000-0000-000000000000', 'bob@example.com',
     crypt('password123', gen_salt('bf')), now(),
     '{"provider": "email", "providers": ["email"]}'::jsonb,
     '{"display_name": "Bob Martinez"}'::jsonb,
     'authenticated', 'authenticated', now(), now()),
    (u_carol, '00000000-0000-0000-0000-000000000000', 'carol@example.com',
     crypt('password123', gen_salt('bf')), now(),
     '{"provider": "email", "providers": ["email"]}'::jsonb,
     '{"display_name": "Carol Davis"}'::jsonb,
     'authenticated', 'authenticated', now(), now()),
    (u_dave, '00000000-0000-0000-0000-000000000000', 'dave@example.com',
     crypt('password123', gen_salt('bf')), now(),
     '{"provider": "email", "providers": ["email"]}'::jsonb,
     '{"display_name": "Dave Wilson"}'::jsonb,
     'authenticated', 'authenticated', now(), now()),
    (u_eve, '00000000-0000-0000-0000-000000000000', 'eve@example.com',
     crypt('password123', gen_salt('bf')), now(),
     '{"provider": "email", "providers": ["email"]}'::jsonb,
     '{"display_name": "Eve Johnson"}'::jsonb,
     'authenticated', 'authenticated', now(), now()),
    (u_frank, '00000000-0000-0000-0000-000000000000', 'frank@example.com',
     crypt('password123', gen_salt('bf')), now(),
     '{"provider": "email", "providers": ["email"]}'::jsonb,
     '{"display_name": "Frank Lee"}'::jsonb,
     'authenticated', 'authenticated', now(), now()),
    (u_grace, '00000000-0000-0000-0000-000000000000', 'grace@example.com',
     crypt('password123', gen_salt('bf')), now(),
     '{"provider": "email", "providers": ["email"]}'::jsonb,
     '{"display_name": "Grace Kim"}'::jsonb,
     'authenticated', 'authenticated', now(), now()),
    (u_heidi, '00000000-0000-0000-0000-000000000000', 'heidi@example.com',
     crypt('password123', gen_salt('bf')), now(),
     '{"provider": "email", "providers": ["email"]}'::jsonb,
     '{"display_name": "Heidi Brown"}'::jsonb,
     'authenticated', 'authenticated', now(), now()),
    (u_ivan, '00000000-0000-0000-0000-000000000000', 'ivan@example.com',
     crypt('password123', gen_salt('bf')), now(),
     '{"provider": "email", "providers": ["email"]}'::jsonb,
     '{"display_name": "Ivan Petrov"}'::jsonb,
     'authenticated', 'authenticated', now(), now());

  -- Auth identities (required for complete auth setup)
  insert into auth.identities (
    id, user_id, identity_data, provider, provider_id,
    last_sign_in_at, created_at, updated_at
  ) values
    (u_alice, u_alice, json_build_object('sub', u_alice, 'email', 'alice@example.com')::jsonb, 'email', u_alice::text, now(), now(), now()),
    (u_bob,   u_bob,   json_build_object('sub', u_bob,   'email', 'bob@example.com')::jsonb,   'email', u_bob::text,   now(), now(), now()),
    (u_carol, u_carol, json_build_object('sub', u_carol, 'email', 'carol@example.com')::jsonb, 'email', u_carol::text, now(), now(), now()),
    (u_dave,  u_dave,  json_build_object('sub', u_dave,  'email', 'dave@example.com')::jsonb,  'email', u_dave::text,  now(), now(), now()),
    (u_eve,   u_eve,   json_build_object('sub', u_eve,   'email', 'eve@example.com')::jsonb,   'email', u_eve::text,   now(), now(), now()),
    (u_frank, u_frank, json_build_object('sub', u_frank, 'email', 'frank@example.com')::jsonb, 'email', u_frank::text, now(), now(), now()),
    (u_grace, u_grace, json_build_object('sub', u_grace, 'email', 'grace@example.com')::jsonb, 'email', u_grace::text, now(), now(), now()),
    (u_heidi, u_heidi, json_build_object('sub', u_heidi, 'email', 'heidi@example.com')::jsonb, 'email', u_heidi::text, now(), now(), now()),
    (u_ivan,  u_ivan,  json_build_object('sub', u_ivan,  'email', 'ivan@example.com')::jsonb,  'email', u_ivan::text,  now(), now(), now());

  -- ---- Teams ----
  insert into teams (id, name, slug) values
    (team_eng,  'Engineering',  'engineering'),
    (team_prod, 'Product',      'product'),
    (team_dsgn, 'Design',       'design');

  -- ---- Members ----
  insert into members (id, team_id, user_id, role, email, display_name) values
    -- Engineering
    (m_alice, team_eng, u_alice, 'owner',  'alice@example.com',  'Alice Chen'),
    (m_bob,   team_eng, u_bob,   'admin',  'bob@example.com',    'Bob Martinez'),
    (m_carol, team_eng, u_carol, 'member', 'carol@example.com',  'Carol Davis'),
    -- Product
    (m_dave,  team_prod, u_dave,  'owner',  'dave@example.com',  'Dave Wilson'),
    (m_eve,   team_prod, u_eve,   'admin',  'eve@example.com',   'Eve Johnson'),
    (m_frank, team_prod, u_frank, 'member', 'frank@example.com', 'Frank Lee'),
    -- Design
    (m_grace, team_dsgn, u_grace, 'owner',  'grace@example.com', 'Grace Kim'),
    (m_heidi, team_dsgn, u_heidi, 'admin',  'heidi@example.com', 'Heidi Brown'),
    (m_ivan,  team_dsgn, u_ivan,  'member', 'ivan@example.com',  'Ivan Petrov');

  -- ---- Projects ----
  insert into projects (id, team_id, name, description, status, created_by) values
    (p_api,     team_eng,  'API Platform',      'Core REST and GraphQL API services',         'active',   m_alice),
    (p_mobile,  team_eng,  'Mobile App v2',     'Next-gen mobile application rewrite',        'active',   m_bob),
    (p_launch,  team_prod, 'Q3 Product Launch', 'Major feature release for Q3',               'active',   m_dave),
    (p_rebrand, team_dsgn, 'Brand Refresh',     'Company rebrand — logo, colors, typography', 'on_hold',  m_grace),
    (p_archive, team_prod, 'Legacy Dashboard',  'Old analytics dashboard (deprecated)',       'archived', m_eve);

  -- ---- Tasks (18 total, spread across projects and statuses) ----
  -- API Platform tasks (6)
  insert into tasks (id, project_id, title, description, status, priority, assignee_id, reporter_id, due_date, metadata) values
    (t1,                 p_api, 'Implement rate limiting middleware',     'Add per-user rate limits to all API endpoints',                'in_progress', 'high',   m_alice, m_bob,   current_date + 7,   '{"estimated_hours": 16, "sprint": 14}'),
    (t2,                 p_api, 'Add OpenAPI spec generation',           'Auto-generate OpenAPI 3.1 spec from route definitions',        'todo',        'medium', m_bob,   m_alice, current_date + 14,  '{"estimated_hours": 8}'),
    (t3,                 p_api, 'Fix N+1 query in /users endpoint',     'DataLoader batching needed for user-teams resolution',         'in_review',   'urgent', m_carol, m_alice, current_date - 2,   '{"estimated_hours": 4, "bug": true}'),
    (gen_random_uuid(),  p_api, 'Database connection pooling',           'Switch from direct connections to PgBouncer',                  'done',        'high',   m_alice, m_bob,   current_date - 10,  '{"estimated_hours": 12, "sprint": 13}'),
    (gen_random_uuid(),  p_api, 'Add request tracing headers',          'Propagate X-Request-ID through all middleware',                'todo',        'low',    m_carol, m_bob,   null,               '{}'),
    (gen_random_uuid(),  p_api, 'Migrate auth to JWT RS256',            'Switch from HS256 to RS256 for token signing',                 'todo',        'high',   m_bob,   m_alice, current_date + 30,  '{"security_review": true}');

  -- Mobile App v2 tasks (5)
  insert into tasks (project_id, title, description, status, priority, assignee_id, reporter_id, due_date, metadata) values
    (p_mobile, 'Offline sync engine',                'Implement conflict-free replicated data types for offline mode',  'in_progress', 'urgent', m_bob,   m_alice, current_date + 5,  '{"estimated_hours": 40, "sprint": 14}'),
    (p_mobile, 'Push notification service',          'FCM + APNs integration with per-user preferences',               'todo',        'medium', m_carol, m_bob,   current_date + 21, '{"estimated_hours": 20}'),
    (p_mobile, 'Biometric auth integration',         'Face ID / fingerprint login flow',                               'done',        'high',   m_carol, m_alice, current_date - 5,  '{"estimated_hours": 12, "sprint": 13}'),
    (p_mobile, 'App size optimization',              'Reduce APK/IPA size below 15MB',                                 'in_review',   'medium', m_alice, m_bob,   current_date + 3,  '{"current_size_mb": 23}'),
    (p_mobile, 'Deep linking support',               'Universal links / app links for all content types',              'todo',        'low',    null,    m_alice, null,              '{}');

  -- Q3 Product Launch tasks (4)
  insert into tasks (id, project_id, title, description, status, priority, assignee_id, reporter_id, due_date, metadata) values
    (t4,                 p_launch, 'Write launch blog post',             'Technical deep-dive blog post for engineering audience',       'in_progress', 'medium', m_eve,   m_dave, current_date + 10,  '{"word_count_target": 2000}'),
    (t5,                 p_launch, 'Competitive analysis update',        'Refresh competitor feature matrix for Q3',                    'todo',        'high',   m_frank, m_dave, current_date + 7,   '{}'),
    (gen_random_uuid(),  p_launch, 'Pricing page redesign',             'A/B test new pricing tiers',                                  'todo',        'urgent', m_eve,   m_dave, current_date + 14,  '{"variants": ["control", "simplified", "enterprise"]}'),
    (gen_random_uuid(),  p_launch, 'Update onboarding flow',            'Reduce time-to-value from 5min to under 2min',                'done',        'high',   m_frank, m_eve,  current_date - 3,   '{"current_ttv_seconds": 300, "target_ttv_seconds": 120}');

  -- Brand Refresh tasks (2 — project is on_hold)
  insert into tasks (project_id, title, description, status, priority, assignee_id, reporter_id, due_date, metadata) values
    (p_rebrand, 'Logo concept exploration',   'Present 3 logo directions to leadership',      'in_progress', 'medium', m_heidi, m_grace, null,   '{"concepts": 3}'),
    (p_rebrand, 'Color palette definition',   'Define primary, secondary, and accent colors',  'todo',        'medium', m_ivan,  m_grace, null,   '{}');

  -- Legacy Dashboard task (1 — archived project)
  insert into tasks (project_id, title, description, status, priority, assignee_id, reporter_id, due_date, metadata) values
    (p_archive, 'Sunset legacy endpoints',    'Remove deprecated v1 API endpoints',            'done',        'low',    m_frank, m_dave, current_date - 30, '{"deprecated_since": "2025-01-15"}');

  -- ---- Documents (4) ----
  insert into documents (project_id, title, file_path, file_size_bytes, mime_type, uploaded_by) values
    (p_api,     'API Design Document',    team_eng::text  || '/api-design-v2.pdf',        245760,  'application/pdf',  m_alice),
    (p_api,     'Architecture Diagram',   team_eng::text  || '/architecture.png',         102400,  'image/png',        m_bob),
    (p_launch,  'Launch Checklist',       team_prod::text || '/q3-launch-checklist.xlsx',  51200,  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', m_dave),
    (p_rebrand, 'Brand Guidelines Draft', team_dsgn::text || '/brand-guidelines-v1.pdf', 1048576, 'application/pdf',  m_grace);

  -- ---- Comments (8, including one thread) ----
  insert into comments (id, task_id, author_id, body, parent_id) values
    (c1, t1, m_bob, 'Should we use a token bucket or sliding window approach?', null),
    (gen_random_uuid(), t1, m_alice, 'Token bucket — simpler to implement and Redis-native. Sliding window adds complexity we don''t need yet.', c1),
    (gen_random_uuid(), t1, m_carol, 'Agreed. I can help with the Redis integration — I did something similar at my last company.', c1);

  insert into comments (task_id, author_id, body) values
    (t3, m_alice, 'This is causing p95 latency spikes. Flagging as urgent.'),
    (t3, m_carol, 'Root cause identified — we''re resolving team memberships inside a loop. DataLoader PR is up.');

  insert into comments (task_id, author_id, body) values
    (t4, m_dave,  'Let''s target 1,500-2,000 words. Focus on the technical architecture decisions.'),
    (t5, m_frank, 'I''ve started the competitor matrix. Should I include pricing tiers or just features?'),
    (t5, m_dave,  'Both — pricing is actually our strongest differentiator right now.');

  -- ---- Task Embeddings (synthetic 384-dim vectors for all tasks) ----
  -- Tests: execute_sql with vector operators, match_tasks() RPC, HNSW index
  -- Uses deterministic pseudo-random vectors derived from task hashtext for reproducibility
  insert into task_embeddings (task_id, embedding)
  select
    t.id,
    (
      select array_agg(
        sin(hashtext(t.id::text || i::text)::float / 1000.0) * 0.1
      )::extensions.vector(384)
      from generate_series(1, 384) as i
    )
  from tasks t;

end $$;

-- ============================================================================
-- SECTION 13: Verification Queries (uncomment to test manually)
-- These map directly to MCP eval scenarios
-- ============================================================================

-- -- Test: execute_sql simple SELECT
-- select * from teams;

-- -- Test: execute_sql with 2-table JOIN
-- select m.display_name, m.role, t.name as team
-- from members m join teams t on t.id = m.team_id
-- order by t.name, m.role;

-- -- Test: execute_sql with the task_details view (4-table JOIN + security_invoker)
-- select task_id, title, task_status, priority, project_name, team_name, assignee_name
-- from task_details
-- order by task_created_at desc;

-- -- Test: execute_sql with aggregation
-- select task_status, count(*) as cnt
-- from tasks
-- group by task_status
-- order by cnt desc;

-- -- Test: execute_sql with JSONB filter
-- select title, metadata->>'estimated_hours' as hours
-- from tasks
-- where metadata ? 'estimated_hours'
-- order by (metadata->>'estimated_hours')::int desc;

-- -- Test: execute_sql with JSONB containment
-- select title from tasks where metadata @> '{"bug": true}';

-- -- Test: execute_sql with date filter (overdue tasks)
-- select title, due_date, status from tasks
-- where due_date < current_date and status != 'done';

-- -- Test: execute_sql with pagination
-- select title, status from tasks order by created_at limit 5 offset 5;

-- -- Test: execute_sql calling RPC function (JSON return)
-- select get_team_dashboard((select id from teams where slug = 'engineering'));

-- -- Test: execute_sql calling table-returning RPC function
-- select * from search_tasks('auth', (select id from teams where slug = 'engineering'));

-- -- Test: execute_sql with vector similarity search (pgvector)
-- select * from match_tasks(
--   (select embedding from task_embeddings limit 1),  -- use first task's embedding as query
--   0.0,  -- low threshold to return results with synthetic vectors
--   5
-- );

-- -- Test: trigger verification — audit_log was populated by task inserts
-- select table_name, action, record_id, changed_at
-- from audit_log
-- order by changed_at desc
-- limit 10;

-- -- Test: self-referential query — threaded comments
-- select
--   c.body,
--   a.display_name as author,
--   parent.body as replying_to
-- from comments c
-- join members a on a.id = c.author_id
-- left join comments parent on parent.id = c.parent_id
-- order by c.created_at;

-- -- Test: execute_sql with window function
-- select
--   title, status, priority,
--   row_number() over (partition by status order by created_at) as rank_in_status
-- from tasks;

-- -- Test: auth user seeding verification
-- select u.id, u.email, u.raw_user_meta_data->>'display_name' as name
-- from auth.users u
-- order by u.email;

-- -- Test: auth.jwt() claim extraction pattern
-- select auth.jwt()->>'role' as current_role;
