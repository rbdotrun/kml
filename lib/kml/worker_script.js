function parseCookies(cookieHeader) {
  const cookies = {};
  if (!cookieHeader) return cookies;
  cookieHeader.split(';').forEach(cookie => {
    const [name, ...rest] = cookie.trim().split('=');
    if (name) cookies[name] = rest.join('=');
  });
  return cookies;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    // Assets don't need auth - pass through
    if (path.startsWith('/assets/') || path.startsWith('/icon')) {
      return fetch(env.DAYTONA_PREVIEW_URL + path, {
        headers: { 'x-daytona-preview-token': env.DAYTONA_PREVIEW_TOKEN }
      });
    }

    const cookies = parseCookies(request.headers.get('Cookie') || '');
    const tokenParam = url.searchParams.get('token');
    const cookieToken = cookies['kml_token'];

    const token = tokenParam || cookieToken;
    if (!token || token !== env.ACCESS_TOKEN) {
      return new Response('Not Found', { status: 404 });
    }

    // First visit with token - set cookie and redirect to clean URL
    if (tokenParam) {
      url.searchParams.delete('token');
      return new Response(null, {
        status: 302,
        headers: {
          'Location': url.toString(),
          'Set-Cookie': `kml_token=${token}; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=86400`,
          'Cache-Control': 'no-store'
        }
      });
    }

    // Proxy to Daytona with preview token
    const daytonaUrl = env.DAYTONA_PREVIEW_URL + url.pathname + url.search;
    return fetch(daytonaUrl, {
      method: request.method,
      headers: {
        ...Object.fromEntries(request.headers),
        'x-daytona-preview-token': env.DAYTONA_PREVIEW_TOKEN
      },
      body: request.body
    });
  }
};
