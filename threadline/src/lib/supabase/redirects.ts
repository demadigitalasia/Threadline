/** Build Auth callback URLs from the configured public site URL. */
export function getAuthRedirectUrl(path: string) {
  const baseUrl = process.env.NEXT_PUBLIC_SITE_URL ?? window.location.origin;
  return new URL(path, baseUrl).toString();
}
