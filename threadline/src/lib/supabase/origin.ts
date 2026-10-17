/**
 * Check the browser Origin against the configured public site URL first. When
 * the app is behind a reverse proxy, request.url may contain an internal host;
 * forwarded host/protocol headers are the fallback for other allowed hosts.
 */
export function hasSameOrigin(request: Request) {
  const origin = request.headers.get("origin");
  if (!origin) return false;

  try {
    const originUrl = new URL(origin);
    const configuredSiteUrl = process.env.NEXT_PUBLIC_SITE_URL;
    if (configuredSiteUrl && originUrl.origin === new URL(configuredSiteUrl).origin) return true;

    const requestUrl = new URL(request.url);
    const forwardedHost = request.headers.get("x-forwarded-host")?.split(",", 1)[0]?.trim();
    const host = forwardedHost || request.headers.get("host") || requestUrl.host;
    const forwardedProtocol = request.headers.get("x-forwarded-proto")?.split(",", 1)[0]?.trim();
    const protocol = forwardedProtocol || requestUrl.protocol.slice(0, -1);
    return originUrl.origin === new URL(`${protocol}://${host}`).origin;
  } catch {
    return false;
  }
}
