-- Prontuário Pré-Anestésico: convite por WhatsApp para o paciente ler o TCLE
-- com antecedência e marcar que leu/entendeu cada declaração (sem assinar —
-- a assinatura continua sendo feita presencialmente, como já era).
-- Mesma arquitetura do convite do "Questionário do paciente" (convites_paciente).

create table public.convites_tcle (
  id uuid primary key default gen_random_uuid(),
  avaliacao_id uuid not null references public.avaliacoes(id),
  token_hash text not null,
  telefone text,
  criado_por uuid not null default auth.uid(),
  criado_em timestamptz not null default now(),
  expira_em timestamptz not null,
  revogado boolean not null default false,
  aberto_em timestamptz,
  respondido_em timestamptz,
  atualizado_em timestamptz,
  importado_em timestamptz,
  importado_por uuid,
  respostas jsonb
);
alter table public.convites_tcle enable row level security;
create policy convites_tcle_ler on public.convites_tcle for select to authenticated
  using (exists (select 1 from public.avaliacoes a where a.id = convites_tcle.avaliacao_id and private.ve_instituicao(a.instituicao_id)));

create or replace function public.tcle_convite_criar(p_avaliacao uuid, p_dias integer, p_telefone text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare a public.avaliacoes; tok text; exp timestamptz;
begin
  if private.minha_funcao() is null then raise exception 'Usuário sem acesso ao sistema.'; end if;
  if private.nivel_aba('tcle') <> 'editar' then raise exception 'Sua função não pode enviar o termo de consentimento.'; end if;
  select * into a from public.avaliacoes where id = p_avaliacao;
  if a.id is null or not private.ve_instituicao(a.instituicao_id) then raise exception 'Prontuário não encontrado.'; end if;
  if a.status <> 'rascunho' then raise exception 'Este prontuário já está assinado.'; end if;
  update public.convites_tcle set revogado = true where avaliacao_id = p_avaliacao and respondido_em is null and not revogado;
  tok := translate(encode(extensions.gen_random_bytes(24), 'base64'), '+/=', '-_.');
  exp := now() + make_interval(days => greatest(1, least(coalesce(p_dias, 7), 30)));
  insert into public.convites_tcle (avaliacao_id, token_hash, telefone, expira_em)
  values (p_avaliacao, encode(extensions.digest(tok, 'sha256'), 'hex'), nullif(left(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), 20), ''), exp);
  insert into public.audit_log (actor_id, actor_papel, acao, tabela, registro_id, detalhe)
  values (auth.uid(), private.minha_funcao(), 'insert', 'convites_tcle', p_avaliacao, jsonb_build_object('evento', 'tcle.enviado', 'dias', p_dias));
  return jsonb_build_object('token', tok, 'expira_em', exp);
end $function$;

create or replace function public.tcle_convite_importado(p_convite uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare c public.convites_tcle; a public.avaliacoes;
begin
  select * into c from public.convites_tcle where id = p_convite;
  if c.id is null then raise exception 'Convite não encontrado.'; end if;
  select * into a from public.avaliacoes where id = c.avaliacao_id;
  if a.id is null or not private.ve_instituicao(a.instituicao_id) or private.minha_funcao() is null then raise exception 'Sem acesso.'; end if;
  update public.convites_tcle set importado_em = now(), importado_por = auth.uid() where id = p_convite;
  insert into public.audit_log (actor_id, actor_papel, acao, tabela, registro_id, detalhe)
  values (auth.uid(), private.minha_funcao(), 'update', 'convites_tcle', c.avaliacao_id, jsonb_build_object('evento', 'tcle.importado'));
end $function$;

create or replace function public.tcle_abrir(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare c public.convites_tcle; a public.avaliacoes; inst text; dplano jsonb; dproc jsonb;
begin
  if p_token is null or length(p_token) < 20 or length(p_token) > 100 then return jsonb_build_object('erro', 'link_invalido'); end if;
  select * into c from public.convites_tcle where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
  if c.id is null or c.revogado then return jsonb_build_object('erro', 'link_invalido'); end if;
  if c.respondido_em is not null then return jsonb_build_object('erro', 'ja_enviado'); end if;
  if c.expira_em < now() then return jsonb_build_object('erro', 'expirado'); end if;
  update public.convites_tcle set aberto_em = coalesce(aberto_em, now()) where id = c.id;
  select * into a from public.avaliacoes where id = c.avaliacao_id;
  select nome into inst from public.instituicoes where id = a.instituicao_id;
  select dados into dplano from public.avaliacao_secoes where avaliacao_id = a.id and aba_id = 'plano';
  select dados into dproc from public.avaliacao_secoes where avaliacao_id = a.id and aba_id = 'proc';
  return jsonb_build_object('primeiro_nome', split_part(coalesce(a.paciente_nome, ''), ' ', 1), 'instituicao', inst,
    'cirurgia', a.cirurgia, 'data_cirurgia', a.data_cirurgia, 'hora_cirurgia', dproc -> 'hora_cir',
    'cirurgiao', dproc -> 'cirurgiao', 'tecnica', coalesce(dplano -> 'tecnica', '[]'::jsonb), 'tec_bloqueio', dplano -> 'tec_bloqueio',
    'expira_em', c.expira_em, 'estado', coalesce(c.respostas -> 'estado', 'null'::jsonb));
end $function$;

create or replace function public.tcle_salvar(p_token text, p_dados jsonb, p_finalizar boolean)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare c public.convites_tcle;
begin
  if p_token is null or length(p_token) < 20 or length(p_token) > 100 then return jsonb_build_object('erro', 'link_invalido'); end if;
  if p_dados is null or jsonb_typeof(p_dados) <> 'object' or length(p_dados::text) > 300000 then return jsonb_build_object('erro', 'dados_invalidos'); end if;
  select * into c from public.convites_tcle where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex') for update;
  if c.id is null or c.revogado then return jsonb_build_object('erro', 'link_invalido'); end if;
  if c.respondido_em is not null then return jsonb_build_object('erro', 'ja_enviado'); end if;
  if c.expira_em < now() then return jsonb_build_object('erro', 'expirado'); end if;
  if c.atualizado_em is not null and c.atualizado_em > now() - interval '2 seconds' and not coalesce(p_finalizar, false) then return jsonb_build_object('ok', true, 'ignorado', true); end if;
  update public.convites_tcle set respostas = p_dados, atualizado_em = now(),
    respondido_em = case when coalesce(p_finalizar, false) then now() else null end
  where id = c.id;
  return jsonb_build_object('ok', true, 'finalizado', coalesce(p_finalizar, false));
end $function$;

grant execute on function public.tcle_convite_criar(uuid, integer, text) to authenticated;
grant execute on function public.tcle_convite_importado(uuid) to authenticated;
grant execute on function public.tcle_abrir(text) to anon, authenticated;
grant execute on function public.tcle_salvar(text, jsonb, boolean) to anon, authenticated;
