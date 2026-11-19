begin;
set local search_path = public, extensions, pg_temp;
select no_plan();

insert into auth.users(id, email) values
  ('11111111-1111-1111-1111-111111111111', 'slice-a@example.invalid'),
  ('22222222-2222-2222-2222-222222222222', 'slice-b@example.invalid'),
  ('33333333-3333-3333-3333-333333333333', 'slice-rollback@example.invalid');

select ok(not rolcanlogin and not rolbypassrls and not rolsuper and not rolcreaterole,
  'helper owner has no login or global authority') from pg_roles where rolname = 'keepsake_group_writer';
select ok(not pg_has_role('authenticated', 'keepsake_group_writer', 'MEMBER'), 'clients cannot become the writer');
select ok(not pg_has_role('anon', 'keepsake_group_writer', 'MEMBER'), 'anonymous callers cannot become the writer');
select ok(relrowsecurity and relforcerowsecurity, 'groups force RLS') from pg_class where oid = 'public.groups'::regclass;
select ok(relrowsecurity and relforcerowsecurity, 'members force RLS') from pg_class where oid = 'public.group_members'::regclass;
select ok(not has_table_privilege('keepsake_group_writer', 'public.groups', 'UPDATE,DELETE,TRUNCATE'), 'writer cannot update delete or truncate');
select ok(not has_table_privilege('keepsake_group_writer', 'public.group_members', 'UPDATE,DELETE,TRUNCATE'), 'writer cannot edit members');
select ok(not has_function_privilege('anon', 'public.create_solo_group(uuid,text)', 'EXECUTE'), 'anon has no RPC grant');
select ok(not has_function_privilege('anon', 'private.create_solo_group_impl(uuid,text)', 'EXECUTE'), 'anon has no helper grant');
select ok(not prosecdef, 'public wrapper is invoker') from pg_proc where oid = 'public.create_solo_group(uuid,text)'::regprocedure;
select ok(prosecdef and proowner = 'keepsake_group_writer'::regrole and proconfig @> array['search_path=""'], 'private helper has narrow owner and empty search path')
  from pg_proc where oid = 'private.create_solo_group_impl(uuid,text)'::regprocedure;

set local role anon;
select throws_ok($$select * from public.groups$$, '42501', null, 'anon cannot read groups');
select throws_ok($$select * from public.group_members$$, '42501', null, 'anon cannot read members');
select throws_ok($$select public.create_solo_group('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A')$$, '42501', null, 'anon cannot create');
reset role;

select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
select lives_ok($$select public.create_solo_group('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', ' Café ')$$, 'A creates group and owner membership atomically');
select results_eq($$select name from public.groups$$, array['Café']::text[], 'canonical name is stored');
select is((select count(*) from public.groups), 1::bigint, 'one owned group');
select is((select count(*) from public.group_members where role = 'owner' and user_id = auth.uid()), 1::bigint, 'exactly one self owner membership');
select is(public.create_solo_group('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Café')->>'outcome', 'replayed', 'exact replay is idempotent');
select throws_ok($$select public.create_solo_group('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Rename')$$, 'KSG03', 'operation_conflict', 'same request cannot rename');
select throws_ok($$select public.create_solo_group('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Second')$$, 'KSG02', 'solo_group_exists', 'new request cannot create a second group');
select throws_ok($$select public.create_solo_group(null, 'X')$$, 'KSG01', 'invalid_group_name', 'null operation rejected');
select throws_ok($$select public.create_solo_group('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', E'\t')$$, 'KSG01', 'invalid_group_name', 'control input rejected');
select throws_ok($$select public.create_solo_group('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', U&'\00A0')$$, 'KSG01', 'invalid_group_name', 'nonbreaking-space-only name rejected independently of locale');
select throws_ok($$select public.create_solo_group('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', U&'a\0085b')$$, 'KSG01', 'invalid_group_name', 'embedded non-ASCII control rejected');
select throws_ok($$select public.create_solo_group('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', repeat('😀', 80))$$, 'KSG03', 'operation_conflict', '80 emoji scalars pass name validation but cannot rename');
select throws_ok($$select public.create_solo_group('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', repeat('😀', 81))$$, 'KSG01', 'invalid_group_name', '81 emoji scalars exceed limit');
select throws_ok($$select public.create_solo_group('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', repeat('a', 81))$$, 'KSG01', 'invalid_group_name', 'overlong input rejected');
select throws_ok($$select public.create_solo_group('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', repeat('a', 4097))$$, 'KSG01', 'invalid_group_name', 'raw byte bound enforced');
select throws_ok($$insert into public.groups(owner_id,name,create_operation_id) values(auth.uid(),'Direct','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')$$, '42501', null, 'direct group insertion denied');
select throws_ok($$update public.groups set name = 'Rename'$$, '42501', null, 'direct group update denied');
select throws_ok($$delete from public.groups$$, '42501', null, 'direct group deletion denied');
select throws_ok($$insert into public.group_members select * from public.group_members$$, '42501', null, 'direct membership insertion denied');
select throws_ok($$update public.group_members set role = 'owner'$$, '42501', null, 'direct membership update denied');
select throws_ok($$delete from public.group_members$$, '42501', null, 'direct membership deletion denied');
reset role;

select set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}', true);
set local role authenticated;
select is((select count(*) from public.groups), 0::bigint, 'B sees no A group');
select is((select count(*) from public.group_members), 0::bigint, 'B sees no A membership');
select lives_ok($$select public.create_solo_group('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'B')$$, 'operation UUID grants no cross-user authority');
select results_eq($$select name from public.groups$$, array['B']::text[], 'B sees only B');
select is((select count(*) from public.group_members where user_id <> auth.uid()), 0::bigint, 'B sees no other member');
reset role;

create function pg_temp.reject_membership() returns trigger language plpgsql as $$
begin
  raise exception using errcode = 'P0001', message = 'isolated_membership_failure';
end;
$$;
create trigger slice1_test_membership_failure before insert on public.group_members
  for each row execute function pg_temp.reject_membership();
select set_config('request.jwt.claims', '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}', true);
set local role authenticated;
select throws_ok($$select public.create_solo_group('cccccccc-cccc-cccc-cccc-cccccccccccc', 'Rollback')$$, 'P0001', 'isolated_membership_failure', 'membership failure aborts RPC');
select is((select count(*) from public.groups), 0::bigint, 'failed RPC leaves no group');
select is((select count(*) from public.group_members), 0::bigint, 'failed RPC leaves no membership');
reset role;
drop trigger slice1_test_membership_failure on public.group_members;

select throws_ok($$insert into public.groups(owner_id,name,create_operation_id) values('33333333-3333-3333-3333-333333333333','Orphan','cccccccc-cccc-cccc-cccc-cccccccccccc'); set constraints group_requires_owner_member immediate;$$,
  '23503', null, 'deferred constraint rejects orphan at commit boundary');
select throws_ok($$insert into public.group_members(group_id,user_id) select id,'33333333-3333-3333-3333-333333333333' from public.groups limit 1$$, '23505', null, 'second membership cannot be added');
set constraints all immediate;
select is((select count(*) from public.groups), 2::bigint, 'only A and B groups remain');
select is((select count(*) from public.group_members), 2::bigint, 'each group has exactly its owner');
select * from finish();
rollback;
