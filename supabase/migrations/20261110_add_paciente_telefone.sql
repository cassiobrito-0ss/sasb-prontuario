-- Prontuário Pré-Anestésico: coluna de telefone/WhatsApp do paciente em avaliacoes,
-- preenchida ao criar o "Novo prontuário" e replicada para o campo "telefone" da
-- Seção 01 (Identificação).
alter table public.avaliacoes add column if not exists paciente_telefone text;
