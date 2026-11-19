-- 주의: 이미 운영 중인 예하·정현 서버에는 이 초기 설정 파일을 다시 실행하지 마세요.
-- 친구 커플 추가 및 200문항 지원에는 migration_add_sangjun_couple.sql을 실행해야 합니다.
-- 본 파일은 최초 버전의 초기 설정 예시이며, 다중 커플 전환용 파일이 아닙니다.

-- Supabase SQL Editor에 전체 붙여 넣고 Run을 누르세요.
-- 로그인 없는 두 사람의 전용 링크 방식. 토큰은 SHA-256 해시로만 보관합니다.
-- 이 파일은 새 Supabase 프로젝트용입니다. 기존 로그인 버전 DB와 별개 테이블을 씁니다.

create table if not exists public.private_couple_keys (
  role text primary key check (role in ('yeha','junghyun')),
  token_hash text not null unique check (length(token_hash)=64)
);
create table if not exists public.private_couple_entries (
  question_id integer not null check (question_id between 1 and 200),
  role text not null check (role in ('yeha','junghyun')),
  answer text not null check (length(btrim(answer)) > 0 and length(answer)<=10000),
  different boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (question_id, role)
);

alter table public.private_couple_keys enable row level security;
alter table public.private_couple_entries enable row level security;
revoke all on public.private_couple_keys from public, anon, authenticated;
revoke all on public.private_couple_entries from public, anon, authenticated;

-- 유효한 비밀 코드를 가진 사용자만 접근할 수 있도록, 직접 테이블 API 대신 RPC 사용
create or replace function public.couple_state(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  who text;
  entries jsonb;
begin
  if p_token is null or length(p_token) > 120 then
    raise exception '올바르지 않은 접속 코드입니다';
  end if;
  select k.role into who from public.private_couple_keys k
  where k.token_hash = encode(sha256(convert_to(p_token,'UTF8')),'hex');
  if who is null then raise exception '접속 코드가 올바르지 않습니다'; end if;

  -- 타인의 답변은 두 사람 모두 제출한 질문에 대해서만 읽을 수 있음
  select coalesce(jsonb_agg(jsonb_build_object(
    'question_id', e.question_id,
    'role', e.role,
    'answer', case when e.role=who or exists (
      select 1 from public.private_couple_entries x
      where x.question_id=e.question_id and x.role=who
    ) then e.answer else '[제출 완료]' end,
    'different', case when e.role=who or exists (
      select 1 from public.private_couple_entries x
      where x.question_id=e.question_id and x.role=who
    ) then e.different else false end
  ) order by e.question_id,e.role),'[]'::jsonb)
  into entries from public.private_couple_entries e;
  return jsonb_build_object('role',who,'entries',entries);
end;
$$;

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
revoke all on function public.couple_state(text) from public, anon, authenticated;
revoke all on function public.couple_save(text,integer,text,boolean) from public, anon, authenticated;
grant execute on function public.couple_state(text) to anon;
grant execute on function public.couple_save(text,integer,text,boolean) to anon;

insert into public.private_couple_keys(role,token_hash) values
 ('yeha','e8a7e47db046c30d65812573ece7d8a24b9f85ca504799f0c36e213ba9cd922a'),
 ('junghyun','4f059eb09e550d64b17b4a355f9da709584c3d60425292868dc09fa183ed8821')
on conflict(role) do update set token_hash=excluded.token_hash;
