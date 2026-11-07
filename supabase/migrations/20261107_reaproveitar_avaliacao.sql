-- Reaproveitamento de avaliações anteriores do mesmo paciente
alter table public.avaliacoes add column if not exists origem_id uuid references public.avaliacoes(id) on delete set null;
alter table public.avaliacoes add column if not exists reuso_modo text check (reuso_modo in ('completo','rapido'));
create index if not exists avaliacoes_paciente_idx on public.avaliacoes (paciente_nascimento, lower(paciente_nome));

insert into public.abas (id, ordem, titulo) values ('atualizacao', 0, 'Atualização desde a avaliação anterior')
  on conflict (id) do nothing;
insert into public.permissoes (funcao_id, aba_id, nivel)
  select f.funcao_id, 'atualizacao', case when f.funcao_id in ('admin','medico','anestesiologista') then 'editar' when f.funcao_id = 'secretaria' then 'ver' else 'oculto' end
  from (select distinct funcao_id from public.permissoes) f
  on conflict do nothing;

create or replace function public.reaproveitar_avaliacao(p_origem uuid, p_modo text, p_destino uuid default null)
returns uuid
language plpgsql security definer set search_path to ''
as $$
declare o public.avaliacoes; d public.avaliacoes; novo uuid; idd jsonb;
begin
  if private.minha_funcao() is null then raise exception 'Usuário sem acesso ao sistema.'; end if;
  if private.nivel_aba('ident') <> 'editar' then raise exception 'Sua função não pode criar prontuários.'; end if;
  if p_modo not in ('completo','rapido') then raise exception 'Modo inválido.'; end if;
  select * into o from public.avaliacoes where id = p_origem;
  if o.id is null or not private.ve_instituicao(o.instituicao_id) then raise exception 'Avaliação de origem não encontrada.'; end if;

  if p_destino is null then
    insert into public.avaliacoes (instituicao_id, paciente_nome, paciente_nascimento, paciente_sexo, registro, criado_por, origem_id, reuso_modo)
    values (o.instituicao_id, o.paciente_nome, o.paciente_nascimento, o.paciente_sexo, o.registro, auth.uid(), o.id, p_modo)
    returning id into novo;
  else
    select * into d from public.avaliacoes where id = p_destino for update;
    if d.id is null or not private.ve_instituicao(d.instituicao_id) then raise exception 'Prontuário não encontrado.'; end if;
    if d.status <> 'rascunho' then raise exception 'O prontuário de destino já está assinado.'; end if;
    if d.id = o.id then raise exception 'Escolha uma avaliação anterior diferente desta.'; end if;
    novo := d.id;
    update public.avaliacoes set origem_id = o.id, reuso_modo = p_modo,
      paciente_nascimento = coalesce(paciente_nascimento, o.paciente_nascimento), paciente_sexo = coalesce(paciente_sexo, o.paciente_sexo),
      registro = coalesce(registro, o.registro), atualizado_por = auth.uid(), atualizado_em = now()
    where id = novo;
  end if;

  -- copia as seções clínicas; procedimento, plano, orientações, TCLE e reavaliação começam em branco
  insert into public.avaliacao_secoes (avaliacao_id, aba_id, dados, atualizado_por, atualizado_em)
  select novo, s.aba_id,
         case when s.aba_id = 'ident' then (s.dados - 'data_aval' - 'hora_aval' - 'anestesiologista' - 'crm_anest') || coalesce(x.dados, '{}'::jsonb) else s.dados end,
         auth.uid(), now()
  from public.avaliacao_secoes s
  left join public.avaliacao_secoes x on x.avaliacao_id = novo and x.aba_id = s.aba_id
  where s.avaliacao_id = o.id
    and s.aba_id not in ('proc','plano','orient','tcle','reaval','painel','resumo','atualizacao')
  on conflict (avaliacao_id, aba_id) do update set dados = excluded.dados, atualizado_por = excluded.atualizado_por, atualizado_em = excluded.atualizado_em;

  insert into public.avaliacao_secoes (avaliacao_id, aba_id, dados, atualizado_por, atualizado_em)
  values (novo, 'atualizacao', jsonb_build_object('at_info', jsonb_build_object('origem', o.id, 'origem_data', o.criado_em, 'origem_assinada', o.assinado_em, 'origem_por', o.assinado_nome, 'modo', p_modo)::text), auth.uid(), now())
  on conflict (avaliacao_id, aba_id) do update set dados = excluded.dados, atualizado_em = now();

  insert into public.audit_log (actor_id, actor_papel, acao, tabela, registro_id, detalhe)
  values (auth.uid(), private.minha_funcao(), 'insert', 'avaliacoes', novo, jsonb_build_object('evento', 'avaliacao.reaproveitada', 'origem', o.id, 'modo', p_modo));
  return novo;
end $$;
revoke all on function public.reaproveitar_avaliacao(uuid, text, uuid) from public, anon;
grant execute on function public.reaproveitar_avaliacao(uuid, text, uuid) to authenticated;

-- assinatura: avaliação reaproveitada só assina depois da conferência
create or replace function public.assinar_avaliacao(p_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare p public.profiles; a public.avaliacoes; img text; cred text; h text; conf text;
begin
  select * into p from public.profiles where id = auth.uid() and ativo;
  if p.id is null or not (p.papel = 'medico' or (p.papel = 'admin' and p.crm is not null)) then raise exception 'Apenas médicos com CRM cadastrado podem assinar.'; end if;
  select * into a from public.avaliacoes where id = p_id for update;
  if a.id is null or not private.ve_instituicao(a.instituicao_id) then raise exception 'Prontuário não encontrado.'; end if;
  if a.status = 'assinada' then raise exception 'Este prontuário já está assinado.'; end if;
  if a.reuso_modo is not null then
    select s.dados->>'at_concluido' into conf from public.avaliacao_secoes s where s.avaliacao_id = p_id and s.aba_id = 'atualizacao';
    if coalesce(conf, '') <> '1' then raise exception 'Termine a conferência dos dados copiados da avaliação anterior antes de assinar.'; end if;
  end if;
  select imagem into img from public.assinaturas where user_id = p.id;
  if img is null then raise exception 'Cadastre sua assinatura antes de assinar.'; end if;
  cred := concat_ws(' · ', case when p.crm is not null then 'CRM' || coalesce('-' || p.crm_uf, '') || ' ' || p.crm end,
                         case when p.rqe is not null then 'RQE ' || p.rqe end);
  select encode(extensions.digest(coalesce(string_agg(s.aba_id || ':' || s.dados::text, '|' order by s.aba_id), ''), 'sha256'), 'hex')
    into h from public.avaliacao_secoes s where s.avaliacao_id = p_id;
  update public.avaliacoes set status = 'assinada', assinado_por = p.id, assinado_em = now(), assinado_nome = p.nome_completo,
    assinado_cred = cred, assinatura_img = img, hash_conteudo = h, atualizado_por = p.id, atualizado_em = now()
  where id = p_id;
  return jsonb_build_object('assinado_em', now(), 'assinado_nome', p.nome_completo, 'assinado_cred', cred, 'assinatura_img', img, 'hash', h);
end $function$;
