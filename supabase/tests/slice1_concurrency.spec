setup
{
  INSERT INTO auth.users(id,email) VALUES ('44444444-4444-4444-4444-444444444444','slice-concurrency@example.invalid');
}

teardown
{
  BEGIN;
  SET CONSTRAINTS ALL DEFERRED;
  DELETE FROM public.group_members WHERE user_id = '44444444-4444-4444-4444-444444444444';
  DELETE FROM public.groups WHERE owner_id = '44444444-4444-4444-4444-444444444444';
  DELETE FROM auth.users WHERE id = '44444444-4444-4444-4444-444444444444';
  COMMIT;
}

session "winner"
step "w_begin" { BEGIN ISOLATION LEVEL READ COMMITTED; SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claims','{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}',true); }
step "w_create" { SELECT public.create_solo_group('dddddddd-dddd-dddd-dddd-dddddddddddd','Concurrent')->>'outcome'; }
step "w_commit" { COMMIT; }

session "loser"
step "l_begin" { BEGIN ISOLATION LEVEL READ COMMITTED; SET LOCAL ROLE authenticated; SELECT set_config('request.jwt.claims','{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}',true); }
step "l_same" { SELECT public.create_solo_group('dddddddd-dddd-dddd-dddd-dddddddddddd','Concurrent')->>'outcome'; }
step "l_different" { SELECT public.create_solo_group('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee','Not saved')->>'outcome'; }
step "l_commit" { COMMIT; }
step "l_rollback" { ROLLBACK; }

session "check"
step "check_counts" { SELECT (SELECT count(*) FROM public.groups WHERE owner_id = '44444444-4444-4444-4444-444444444444') AS groups, (SELECT count(*) FROM public.group_members WHERE user_id = '44444444-4444-4444-4444-444444444444') AS members; }

permutation "w_begin" "l_begin" "w_create" "l_same" "w_commit" "l_commit" "check_counts"
permutation "w_begin" "l_begin" "w_create" "l_different" "w_commit" "l_rollback" "check_counts"
