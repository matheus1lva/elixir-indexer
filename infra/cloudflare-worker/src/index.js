/**
 * Sourcify Proxy Worker
 *
 * This Cloudflare Worker acts as a transparent proxy to Sourcify API,
 * helping distribute requests across multiple worker instances to avoid rate limits.
 *
 * Deploy multiple instances of this worker to different Cloudflare accounts
 * for IP rotation.
 */

const SOURCIFY_BASE_URL = 'https://sourcify.dev/server';

// Allowed Sourcify API paths (security measure)
const ALLOWED_PATHS = [
  '/files',
  '/check-all-by-addresses',
  '/check-by-addresses',
  '/repository/contracts',
  '/verify',
  '/session',
];

export default {
  async fetch(request, env, ctx) {
    // Handle CORS preflight
    if (request.method === 'OPTIONS') {
      return handleCORS();
    }

    try {
      const url = new URL(request.url);
      const targetPath = url.pathname;

      // Security: Only allow specific Sourcify API paths
      const isAllowed = ALLOWED_PATHS.some(path => targetPath.startsWith(path));
      if (!isAllowed) {
        return new Response(JSON.stringify({ error: 'Path not allowed' }), {
          status: 403,
          headers: { 'Content-Type': 'application/json' }
        });
      }

      // Build target URL
      const targetUrl = `${SOURCIFY_BASE_URL}${targetPath}${url.search}`;

      // Clone and modify request headers
      const headers = new Headers(request.headers);
      headers.delete('cf-connecting-ip');
      headers.delete('cf-ray');
      headers.delete('cf-visitor');
      headers.delete('x-forwarded-for');
      headers.delete('x-real-ip');
      headers.set('User-Agent', 'Mozilla/5.0 (compatible; BlockchainIndexer/1.0)');

      // Forward the request
      const response = await fetch(targetUrl, {
        method: request.method,
        headers: headers,
        body: request.method !== 'GET' && request.method !== 'HEAD'
          ? request.body
          : undefined,
      });

      // Clone response and add CORS headers
      const responseHeaders = new Headers(response.headers);
      responseHeaders.set('Access-Control-Allow-Origin', '*');
      responseHeaders.set('X-Proxy-Worker', env.WORKER_ID || 'default');

      return new Response(response.body, {
        status: response.status,
        statusText: response.statusText,
        headers: responseHeaders,
      });

    } catch (error) {
      return new Response(JSON.stringify({
        error: 'Proxy error',
        message: error.message
      }), {
        status: 502,
        headers: { 'Content-Type': 'application/json' }
      });
    }
  },
};

function handleCORS() {
  return new Response(null, {
    status: 204,
    headers: {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      'Access-Control-Max-Age': '86400',
    },
  });
}
