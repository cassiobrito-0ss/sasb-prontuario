-- CPF do paciente, opcional, coletado no cadastro de "Novo prontuário" e
-- preenchido automaticamente no campo "CPF" (documento) da Identificação.
alter table public.avaliacoes add column if not exists paciente_cpf text;
