begin;

create schema private;
revoke all on schema private from public, anon, authenticated;
create role keepsake_group_writer nologin noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;

create table public.groups (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete restrict,
  name text not null,
  visibility text not null default 'private' check (visibility = 'private'),
  create_operation_id uuid not null,
  created_at timestamptz not null default now(),
  unique (owner_id),
  unique (id, owner_id),
  check (char_length(name) between 1 and 80),
  check (name = normalize(btrim(name), NFC)),
  check (name !~ U&'[\0001-\001F\007F-\009F]'),
  check (name !~ U&'^[\0009-\000D\0020\0085\00A0\1680\2000-\200A\2028\2029\202F\205F\3000]*$')
);

create table public.group_members (
  group_id uuid not null,
  user_id uuid not null,
  role text not null default 'owner' check (role = 'owner'),
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id),
  unique (group_id),
  foreign key (group_id, user_id) references public.groups(id, owner_id) on delete restrict
);

alter table public.groups add constraint group_requires_owner_member
  foreign key (id, owner_id) references public.group_members(group_id, user_id)
  deferrable initially deferred;
create index group_members_user_id_idx on public.group_members(user_id);
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.groups force row level security;
alter table public.group_members force row level security;

revoke all on public.groups, public.group_members from public, anon, authenticated;
grant select on public.groups, public.group_members to authenticated;
grant usage on schema public, auth, private to keepsake_group_writer;
grant execute on function auth.uid(), auth.role() to keepsake_group_writer;
grant select, insert on public.groups, public.group_members to keepsake_group_writer;
create policy groups_read_self on public.groups for select to authenticated, keepsake_group_writer
  using (owner_id = (select auth.uid()));
create policy group_members_read_self on public.group_members for select to authenticated, keepsake_group_writer
  using (user_id = (select auth.uid()));
create policy groups_insert_self on public.groups for insert to keepsake_group_writer
  with check (owner_id = (select auth.uid()));
create policy group_members_insert_self on public.group_members for insert to keepsake_group_writer
  with check (user_id = (select auth.uid()));

create function private.create_solo_group_impl(p_operation_id uuid, p_name text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_owner uuid := auth.uid();
  v_name text;
  v_group public.groups%rowtype;
  v_outcome text;
begin
  if v_owner is null or auth.role() is distinct from 'authenticated' then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_operation_id is null or p_name is null or octet_length(p_name) > 4096 then
    raise exception using errcode = 'KSG01', message = 'invalid_group_name';
  end if;
  v_name := normalize(btrim(p_name), NFC);
  if char_length(v_name) not between 1 and 80
     or v_name ~ U&'[\0001-\001F\007F-\009F]'
     or v_name ~ U&'^[\0009-\000D\0020\0085\00A0\1680\2000-\200A\2028\2029\202F\205F\3000]*$' then
    raise exception using errcode = 'KSG01', message = 'invalid_group_name';
  end if;

  insert into public.groups(owner_id, name, create_operation_id)
    values (v_owner, v_name, p_operation_id)
    on conflict (owner_id) do nothing returning * into v_group;
  if found then
    insert into public.group_members(group_id, user_id, role) values (v_group.id, v_owner, 'owner');
    v_outcome := 'created';
  else
    select * into strict v_group from public.groups where owner_id = v_owner;
    if v_group.create_operation_id <> p_operation_id then
      raise exception using errcode = 'KSG02', message = 'solo_group_exists';
    end if;
    if v_group.name <> v_name then
      raise exception using errcode = 'KSG03', message = 'operation_conflict';
    end if;
    v_outcome := 'replayed';
  end if;
  if (select count(*) from public.group_members where group_id = v_group.id and user_id = v_owner and role = 'owner') <> 1 then
    raise exception using errcode = 'KSG04', message = 'group_invariant_failed';
  end if;
  return pg_catalog.jsonb_build_object('outcome', v_outcome, 'group', pg_catalog.jsonb_build_object(
    'id', v_group.id, 'owner_id', v_group.owner_id, 'name', v_group.name, 'created_at', v_group.created_at
  ));
end;
$$;

grant create on schema private to keepsake_group_writer;
alter function private.create_solo_group_impl(uuid, text) owner to keepsake_group_writer;
revoke create on schema private from keepsake_group_writer;
revoke all on function private.create_solo_group_impl(uuid, text) from public, anon, authenticated;
grant usage on schema private to authenticated;
grant execute on function private.create_solo_group_impl(uuid, text) to authenticated;

create function public.create_solo_group(p_operation_id uuid, p_name text)
returns jsonb language sql security invoker set search_path = ''
as $$ select private.create_solo_group_impl(p_operation_id, p_name); $$;
revoke all on function public.create_solo_group(uuid, text) from public, anon, authenticated;
grant execute on function public.create_solo_group(uuid, text) to authenticated;

commit;
