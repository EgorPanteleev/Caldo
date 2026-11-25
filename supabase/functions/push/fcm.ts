// Firebase Cloud Messaging's HTTP v1 API, from a service account's key:
// a JWT signed with the key is traded with Google for an hour's access
// token, kept while this instance lives.

export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

// Overridable so the function can be tried against a stand-in server.
const tokenUrl = Deno.env.get("GOOGLE_TOKEN_URL") ??
  "https://oauth2.googleapis.com/token";
const fcmUrl = Deno.env.get("FCM_URL") ?? "https://fcm.googleapis.com";

let held: { token: Promise<string>; until: number } | null = null;

function base64url(bytes: Uint8Array): string {
  let text = "";
  for (const b of bytes) text += String.fromCharCode(b);
  return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function derOf(pem: string): ArrayBuffer {
  const body = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const raw = atob(body);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes.buffer;
}

/** One token asked for at a time: each phone's message waits on it. */
function accessToken(account: ServiceAccount): Promise<string> {
  // A minute's slack, so a token doesn't run out on its way.
  if (held && held.until > Date.now() + 60_000) return held.token;
  const token = askToken(account);
  held = { token, until: Date.now() + 3000 * 1000 };
  // Refused, it is asked for again next time rather than kept.
  token.catch(() => held = null);
  return token;
}

async function askToken(account: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const part = (o: unknown) =>
    base64url(new TextEncoder().encode(JSON.stringify(o)));
  const unsigned = `${part({ alg: "RS256", typ: "JWT" })}.${
    part({
      iss: account.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600,
    })
  }`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    derOf(account.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      key,
      new TextEncoder().encode(unsigned),
    ),
  );
  const res = await fetch(tokenUrl, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${unsigned}.${base64url(signature)}`,
    }),
  });
  if (!res.ok) {
    throw new Error(`Google refused the key: ${res.status} ${await res.text()}`);
  }
  const body = await res.json();
  return body.access_token;
}

/** What became of one message: sent, the token dead, or another failure. */
export type Outcome = "sent" | "gone" | "failed";

/**
 * [data] sent to the phone holding [token], as a data message only: the
 * app draws it itself, so it can stay quiet over the chat already on
 * screen. High priority, or a phone in Doze holds it back; one message a
 * chat waits while the phone is offline (the collapse key), the latest.
 */
export async function send(
  account: ServiceAccount,
  token: string,
  data: Record<string, string>,
  collapse: string,
): Promise<Outcome> {
  const res = await fetch(
    `${fcmUrl}/v1/projects/${account.project_id}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${await accessToken(account)}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        message: {
          token,
          data,
          android: { priority: "HIGH", collapse_key: collapse, ttl: "86400s" },
        },
      }),
    },
  );
  if (res.ok) return "sent";
  const body = await res.text();
  // The app uninstalled, or the token renewed since: never again.
  if (
    res.status === 404 || body.includes("UNREGISTERED") ||
    body.includes("registration-token-not-registered")
  ) {
    return "gone";
  }
  console.error(`FCM refused a message: ${res.status} ${body}`);
  return "failed";
}
