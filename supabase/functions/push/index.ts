// Tells the user's phones of one of their chats, by Firebase push.
//
// Asked by the chat's worker (the chat waits on the user: its turn is
// over, or it asks something) or by the MCP tool `notify` (the agent's own
// word), always as the user: the chat and the phones' tokens are read
// under the user's own rights, so nobody is told of anyone else's chat.
//
// POST { chat: uuid, kind: "waiting" | "asking" | "said", text?: string }
// → { sent: number, muted?: true }
//
// The service account's key is the secret FCM_SERVICE_ACCOUNT, the JSON
// file Firebase hands out, whole.

import { createClient } from "npm:@supabase/supabase-js@2";
import { send, type ServiceAccount } from "./fcm.ts";

const kinds = ["waiting", "asking", "said"];

const answer = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

const clip = (text: string, most: number) =>
  text.length <= most ? text : `${text.slice(0, most - 1).trimEnd()}…`;

/** What the app calls a chat: its title, else its first message's line. */
function nameOf(chat: { title?: string; prompt?: string }): string {
  const title = (chat.title ?? "").trim();
  if (title) return clip(title, 80);
  const line = (chat.prompt ?? "").trim().split("\n")[0];
  return line ? clip(line, 80) : "Chat";
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return answer({ error: "POST only" }, 405);
  const secret = Deno.env.get("FCM_SERVICE_ACCOUNT");
  if (!secret) return answer({ error: "FCM_SERVICE_ACCOUNT is not set" }, 503);
  const account = JSON.parse(secret) as ServiceAccount;

  let ask: { chat?: unknown; kind?: unknown; text?: unknown };
  try {
    ask = await req.json();
  } catch {
    return answer({ error: "Not JSON" }, 400);
  }
  const kind = `${ask.kind ?? ""}`;
  if (typeof ask.chat !== "string" || !kinds.includes(kind)) {
    return answer({ error: `Give chat and kind (${kinds.join(", ")})` }, 400);
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    {
      global: { headers: { Authorization: req.headers.get("Authorization")! } },
      auth: { persistSession: false },
    },
  );
  const { data: chat, error } = await db
    .from("chats")
    .select("id, title, prompt, muted")
    .eq("id", ask.chat)
    .maybeSingle();
  if (error) return answer({ error: error.message }, 500);
  if (!chat) return answer({ error: "No such chat" }, 404);
  // Muted, a chat's waiting goes untold, but not its agent's own word.
  if (chat.muted && kind !== "said") return answer({ sent: 0, muted: true });

  const { data: phones, error: unread } = await db
    .from("push_tokens")
    .select("token");
  if (unread) return answer({ error: unread.message }, 500);

  // FCM's data are strings only, and a message is at most 4KB.
  const data = {
    chat: chat.id,
    kind,
    title: nameOf(chat),
    text: clip(typeof ask.text === "string" ? ask.text.trim() : "", 1000),
  };
  let sent = 0;
  await Promise.all(
    (phones ?? []).map(async ({ token }) => {
      const outcome = await send(account, token, data, chat.id);
      if (outcome === "sent") sent++;
      if (outcome === "gone") {
        await db.from("push_tokens").delete().eq("token", token);
      }
    }),
  );
  return answer({ sent });
});
