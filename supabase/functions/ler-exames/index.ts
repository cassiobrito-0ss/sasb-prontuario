// Prontuário Pré-Anestésico — leitura de laudos de exames pelo Claude (API da Anthropic).
// A chave fica só no servidor (segredo ANTHROPIC_API_KEY do Supabase); a página nunca a recebe.
// Usada pelo Extrator de exames quando o prontuário roda no servidor (fora do claude.ai).
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const resp = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const MODELOS: Record<string, string> = {
  quick: Deno.env.get("MODELO_RAPIDO") || "claude-haiku-4-5-20251001",
  default: Deno.env.get("MODELO") || "claude-sonnet-5-5",
  complex: Deno.env.get("MODELO_COMPLEXO") || "claude-opus-5-5",
};
const TIPOS = ["image/jpeg", "image/png", "image/webp", "image/gif"];

function extrairJson(t: string): unknown {
  let s = t.trim().replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/, "").trim();
  try { return JSON.parse(s); } catch { /* tenta o maior objeto */ }
  const i = s.indexOf("{"), j = s.lastIndexOf("}");
  if (i < 0 || j <= i) throw new Error("sem JSON");
  return JSON.parse(s.slice(i, j + 1));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return resp(405, { erro: "Método não permitido." });

  const servico = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const { data: quem, error: eUser } = await servico.auth.getUser(token);
  if (eUser || !quem?.user) return resp(200, { erro: "Sessão inválida. Entre novamente.", code: "session_expired" });
  const { data: eu } = await servico.from("profiles").select("id, papel, ativo").eq("id", quem.user.id).maybeSingle();
  if (!eu || !eu.ativo || !eu.papel) return resp(200, { erro: "Usuário sem acesso ao sistema.", code: "not_granted" });
  const { data: perm } = await servico.from("permissoes").select("nivel").eq("funcao_id", eu.papel).eq("aba_id", "exames").maybeSingle();
  if (!perm || perm.nivel !== "editar") return resp(200, { erro: "Sua função não pode preencher a aba de exames.", code: "not_granted" });

  let corpo: Record<string, unknown>;
  try { corpo = await req.json(); } catch { return resp(200, { erro: "Requisição inválida." }); }

  const chave = Deno.env.get("ANTHROPIC_API_KEY");
  if (corpo.ping) return resp(200, { ok: !!chave });
  if (!chave) return resp(200, { erro: "A leitura automática não está ativada: falta a chave da API do Claude no servidor.", code: "sampling_disabled" });

  const prompt = typeof corpo.prompt === "string" ? corpo.prompt : "";
  if (!prompt || prompt.length > 120000) return resp(200, { erro: "Pedido de leitura inválido.", code: "prompt_too_large" });
  const imagens = Array.isArray(corpo.imagens) ? corpo.imagens as Array<{ tipo?: string; dados?: string }> : [];
  if (imagens.length > 4) return resp(200, { erro: "Envie no máximo 4 imagens por leitura.", code: "prompt_too_large" });
  for (const im of imagens) {
    if (!im || typeof im.dados !== "string" || !TIPOS.includes(String(im.tipo))) return resp(200, { erro: "Imagem em formato não aceito.", code: "image_rejected" });
    if (im.dados.length > 7_000_000) return resp(200, { erro: "Imagem grande demais (máx. ~5 MB).", code: "image_rejected" });
  }
  const modelo = MODELOS[String(corpo.nivel || "default")] || MODELOS.default;

  const conteudo: unknown[] = imagens.map((im) => ({ type: "image", source: { type: "base64", media_type: im.tipo, data: im.dados } }));
  conteudo.push({ type: "text", text: prompt + "\n\nResponda somente com um objeto JSON válido, sem nenhum texto antes ou depois e sem cercas de código." });

  let r: Response;
  try {
    r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": chave, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model: modelo, max_tokens: 8000, messages: [{ role: "user", content: conteudo }] }),
    });
  } catch (e) {
    return resp(200, { erro: "Sem conexão com o Claude: " + (e instanceof Error ? e.message : String(e)), code: "servidor" });
  }
  const dados = await r.json().catch(() => null) as Record<string, any> | null;
  if (!r.ok) {
    const msg = dados?.error?.message || ("HTTP " + r.status);
    const code = r.status === 429 || r.status === 529 ? "rate_limited" : r.status === 401 || r.status === 403 ? "sampling_disabled" : /image/i.test(msg) ? "image_rejected" : /too long|too large|maximum/i.test(msg) ? "prompt_too_large" : "servidor";
    return resp(200, { erro: "O Claude recusou a leitura: " + msg, code });
  }
  if (dados?.stop_reason === "refusal") return resp(200, { erro: "O conteúdo não pôde ser processado.", code: "refused" });
  const texto = (dados?.content || []).filter((c: any) => c.type === "text").map((c: any) => c.text).join("");
  if (!texto.trim()) return resp(200, { erro: "Nenhuma resposta.", code: "empty_completion" });
  let json: unknown;
  try { json = extrairJson(texto); } catch { return resp(200, { erro: "A resposta não veio no formato esperado.", code: "invalid_json" }); }
  return resp(200, { json, modelo, uso: dados?.usage || null });
});
