-- 기존 답변과 접속 코드를 그대로 보존하는 200문항 확장 마이그레이션.
-- Supabase SQL Editor에서 이 파일 전체를 한 번 실행하세요.
-- 기존 테이블을 삭제하거나 답변 행을 수정하지 않습니다.
begin;
do $$
declare constraint_name text;
begin
  for constraint_name in
    select con.conname
    from pg_constraint con
    where con.conrelid = 'public.private_couple_entries'::regclass
      and con.contype = 'c'
      and pg_get_constraintdef(con.oid) like '%question_id%'
  loop
    execute format('alter table public.private_couple_entries drop constraint %I', constraint_name);
  end loop;
end;
$$;
alter table public.private_couple_entries
  add constraint private_couple_entries_question_id_range
  check (question_id between 1 and 200);

create or replace function public.couple_save(
  p_token text, p_question_id integer, p_answer text, p_different boolean default false
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare who text;
begin
  if p_token is null or length(p_token) > 120 then
    raise exception '올바르지 않은 접속 코드입니다';
  end if;
  select k.role into who from public.private_couple_keys k
  where k.token_hash = encode(sha256(convert_to(p_token,'UTF8')),'hex');
  if who is null then raise exception '접속 코드가 올바르지 않습니다'; end if;
  if p_question_id is null or p_question_id not between 1 and 200
      or p_answer is null or length(btrim(p_answer)) = 0 or length(p_answer)>10000 then
    raise exception '질문 번호 또는 답변이 유효하지 않습니다';
  end if;
  insert into public.private_couple_entries (question_id,role,answer,different,updated_at)
  values (p_question_id,who,p_answer,coalesce(p_different,false),now())
  on conflict(question_id,role) do update set
    answer=excluded.answer,different=excluded.different,updated_at=now();
  return public.couple_state(p_token);
end;
$$;
commit;

-- 확인용(선택): 기존 답변 수 확인
-- select role, count(*) from public.private_couple_entries group by role;
