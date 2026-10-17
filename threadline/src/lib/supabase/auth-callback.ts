import { createClient } from "./client";

const codeExchanges = new Map<string, Promise<boolean>>();

/** Share a one-time PKCE exchange across React effect replays. */
export function exchangeAuthCode(code: string) {
  const existing = codeExchanges.get(code);
  if (existing) return existing;

  const exchange = createClient().auth.exchangeCodeForSession(code)
    .then(({ data, error }) => !error && Boolean(data.session))
    .catch(() => false);
  codeExchanges.set(code, exchange);

  void exchange.then((ok) => {
    if (!ok && codeExchanges.get(code) === exchange) codeExchanges.delete(code);
    else window.setTimeout(() => {
      if (codeExchanges.get(code) === exchange) codeExchanges.delete(code);
    }, 60_000);
  });

  return exchange;
}
