-- 안전한 다중 커플 전환: 기존 예하·정현 답변과 기존 초대 코드는 그대로 유지합니다.
-- Supabase SQL Editor에서 이 파일 전체를 한 번 실행하세요.
-- 신설 커플: 상준 / 상준여친 (비밀 초대 코드는 별도 비공개 파일로 전달).
BEGIN;

ALTER TABLE public.private_couple_keys ADD COLUMN IF NOT EXISTS couple_id text;
ALTER TABLE public.private_couple_keys ADD COLUMN IF NOT EXISTS display_name text;
ALTER TABLE public.private_couple_entries ADD COLUMN IF NOT EXISTS couple_id text;

-- 기존 1~200번 답변을 모두 원래 커플에 연결합니다. 답변 내용이나 번호는 바꾸지 않습니다.
UPDATE public.private_couple_keys
SET couple_id = 'yeha_junghyun'
WHERE couple_id IS NULL;
UPDATE public.private_couple_keys
SET display_name = CASE role WHEN 'yeha' THEN '예하' WHEN 'junghyun' THEN '정현' ELSE role END
WHERE display_name IS NULL;
UPDATE public.private_couple_entries
SET couple_id = 'yeha_junghyun'
WHERE couple_id IS NULL;

ALTER TABLE public.private_couple_keys ALTER COLUMN couple_id SET NOT NULL;
ALTER TABLE public.private_couple_keys ALTER COLUMN display_name SET NOT NULL;
ALTER TABLE public.private_couple_entries ALTER COLUMN couple_id SET NOT NULL;

-- 역할은 커플별로 구분하며, 질문별 답변 키에도 커플 ID를 포함합니다.
ALTER TABLE public.private_couple_keys DROP CONSTRAINT IF EXISTS private_couple_keys_role_check;
ALTER TABLE public.private_couple_entries DROP CONSTRAINT IF EXISTS private_couple_entries_role_check;
ALTER TABLE public.private_couple_keys DROP CONSTRAINT IF EXISTS private_couple_keys_role_allowed;
ALTER TABLE public.private_couple_entries DROP CONSTRAINT IF EXISTS private_couple_entries_role_allowed;
ALTER TABLE public.private_couple_keys ADD CONSTRAINT private_couple_keys_role_allowed
  CHECK (role IN ('yeha','junghyun','sangjun','sangjun_gf'));
ALTER TABLE public.private_couple_entries ADD CONSTRAINT private_couple_entries_role_allowed
  CHECK (role IN ('yeha','junghyun','sangjun','sangjun_gf'));
ALTER TABLE public.private_couple_keys DROP CONSTRAINT IF EXISTS private_couple_keys_pkey;
ALTER TABLE public.private_couple_keys ADD CONSTRAINT private_couple_keys_pkey PRIMARY KEY (couple_id,role);
ALTER TABLE public.private_couple_entries DROP CONSTRAINT IF EXISTS private_couple_entries_pkey;
ALTER TABLE public.private_couple_entries ADD CONSTRAINT private_couple_entries_pkey
  PRIMARY KEY (couple_id,question_id,role);

-- 이전에 200문항 확장 SQL을 실행하지 않았어도 101~200번 답변을 저장할 수 있게 합니다.
DO $$
DECLARE c_name text;
BEGIN
 FOR c_name IN
  SELECT c.conname FROM pg_constraint c
  WHERE c.conrelid = 'public.private_couple_entries'::regclass
   AND c.contype='c' AND pg_get_constraintdef(c.oid) LIKE '%question_id%'
 LOOP
  EXECUTE format('ALTER TABLE public.private_couple_entries DROP CONSTRAINT %I', c_name);
 END LOOP;
END
$$;
ALTER TABLE public.private_couple_entries
  ADD CONSTRAINT private_couple_entries_question_id_range
  CHECK (question_id BETWEEN 1 AND 200);

-- 비밀 코드는 직접 저장하지 않고 SHA-256 해시만 보관합니다.
INSERT INTO public.private_couple_keys (couple_id,role,display_name,token_hash) VALUES
  ('sangjun_couple','sangjun','상준','9260b7cae9b26b7e87da36d77f1ec9e67503901af97a8a08ebf93ccb8b5566d1'),
  ('sangjun_couple','sangjun_gf','상준여친','292dcccf3957efd03d57acc92cb96d4cc62322abf362a89f094eaa0839e698b6')
ON CONFLICT (couple_id,role) DO UPDATE SET
  display_name=EXCLUDED.display_name, token_hash=EXCLUDED.token_hash;

-- 토큰에 연결된 해당 커플 데이터만 반환합니다.
CREATE OR REPLACE FUNCTION public.couple_state(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  who text;
  who_couple text;
  who_name text;
  partner text;
  partner_name text;
  entries jsonb;
BEGIN
  IF p_token IS NULL OR length(p_token)>120 THEN
    RAISE EXCEPTION '올바르지 않은 접속 코드입니다';
  END IF;

  SELECT k.role,k.couple_id,k.display_name INTO who,who_couple,who_name
  FROM public.private_couple_keys k
  WHERE k.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');

  IF who IS NULL THEN RAISE EXCEPTION '접속 코드가 올바르지 않습니다'; END IF;

  SELECT k.role,k.display_name INTO partner,partner_name
  FROM public.private_couple_keys k
  WHERE k.couple_id=who_couple AND k.role<>who LIMIT 1;
  IF partner IS NULL THEN RAISE EXCEPTION '상대방 접속 설정을 확인해 주세요'; END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'question_id',e.question_id,
    'role',e.role,
    'answer',CASE WHEN e.role=who OR EXISTS(
      SELECT 1 FROM public.private_couple_entries x
      WHERE x.couple_id=who_couple AND x.question_id=e.question_id AND x.role=who
    ) THEN e.answer ELSE '[제출 완료]' END,
    'different',CASE WHEN e.role=who OR EXISTS(
      SELECT 1 FROM public.private_couple_entries x
      WHERE x.couple_id=who_couple AND x.question_id=e.question_id AND x.role=who
    ) THEN e.different ELSE false END
  ) ORDER BY e.question_id,e.role),'[]'::jsonb)
  INTO entries
  FROM public.private_couple_entries e
  WHERE e.couple_id=who_couple;

  RETURN jsonb_build_object(
    'role',who,'couple_id',who_couple,'my_name',who_name,
    'partner_role',partner,'partner_name',partner_name,
    'couple_name',CASE WHEN who_couple='sangjun_couple'
      THEN '상준과 상준여친' ELSE '예하와 정현' END,
    'entries',entries);
END;
$$;

CREATE OR REPLACE FUNCTION public.couple_save(
  p_token text, p_question_id integer, p_answer text, p_different boolean DEFAULT false
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  who text;
  who_couple text;
BEGIN
  IF p_token IS NULL OR length(p_token)>120 THEN
    RAISE EXCEPTION '올바르지 않은 접속 코드입니다';
  END IF;

  SELECT k.role,k.couple_id INTO who,who_couple
  FROM public.private_couple_keys k
  WHERE k.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex');
  IF who IS NULL THEN RAISE EXCEPTION '접속 코드가 올바르지 않습니다'; END IF;

  IF p_question_id IS NULL OR p_question_id NOT BETWEEN 1 AND 200
    OR p_answer IS NULL OR length(btrim(p_answer))=0 OR length(p_answer)>10000 THEN
    RAISE EXCEPTION '질문 번호 또는 답변이 유효하지 않습니다';
  END IF;

  INSERT INTO public.private_couple_entries
    (couple_id,question_id,role,answer,different,updated_at)
  VALUES (who_couple,p_question_id,who,p_answer,coalesce(p_different,false),now())
  ON CONFLICT (couple_id,question_id,role) DO UPDATE SET
    answer=EXCLUDED.answer,different=EXCLUDED.different,updated_at=now();

  RETURN public.couple_state(p_token);
END;
$$;

REVOKE ALL ON public.private_couple_keys FROM PUBLIC,anon,authenticated;
REVOKE ALL ON public.private_couple_entries FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.couple_state(text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.couple_save(text,integer,text,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.couple_state(text) TO anon;
GRANT EXECUTE ON FUNCTION public.couple_save(text,integer,text,boolean) TO anon;

COMMIT;

-- 실행 후 선택적으로 검증 (아래는 조회만 합니다):
-- SELECT couple_id,role,display_name FROM public.private_couple_keys ORDER BY couple_id,role;
-- SELECT couple_id,role,count(*) FROM public.private_couple_entries GROUP BY couple_id,role;
