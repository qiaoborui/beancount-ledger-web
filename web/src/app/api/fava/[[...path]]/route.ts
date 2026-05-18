import { NextRequest, NextResponse } from "next/server";
import { requireAuth } from "@/lib/auth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const HOP_BY_HOP_HEADERS = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

const REQUEST_HEADER_DENYLIST = new Set([
  ...HOP_BY_HOP_HEADERS,
  "host",
  "content-length",
  "accept-encoding",
]);

const RESPONSE_HEADER_DENYLIST = new Set([
  ...HOP_BY_HOP_HEADERS,
  "content-encoding",
  "content-length",
  "content-security-policy",
  "x-frame-options",
]);

function favaEnabled(): boolean {
  return process.env.FAVA_ENABLED === "true";
}

function favaBaseUrl(): URL {
  return new URL(process.env.FAVA_INTERNAL_URL || "http://127.0.0.1:5000");
}

function upstreamUrl(request: NextRequest, segments: string[] = []): URL {
  const base = favaBaseUrl();
  const url = new URL(base.toString());
  const basePath = base.pathname.replace(/\/$/, "");
  const suffix = segments.map(encodeURIComponent).join("/");
  url.pathname = suffix ? `${basePath}/${suffix}` : `${basePath}/`;
  url.search = request.nextUrl.search;
  return url;
}

function proxyHeaders(request: NextRequest, upstream: URL): Headers {
  const headers = new Headers();
  request.headers.forEach((value, key) => {
    if (!REQUEST_HEADER_DENYLIST.has(key.toLowerCase())) headers.set(key, value);
  });
  headers.set("host", upstream.host);
  headers.set("x-forwarded-host", request.nextUrl.host);
  headers.set("x-forwarded-proto", request.nextUrl.protocol.replace(":", ""));
  return headers;
}

function responseHeaders(upstreamHeaders: Headers): Headers {
  const headers = new Headers();
  upstreamHeaders.forEach((value, key) => {
    if (!RESPONSE_HEADER_DENYLIST.has(key.toLowerCase())) headers.set(key, value);
  });
  return headers;
}

function rewriteLocation(location: string, request: NextRequest): string {
  const base = favaBaseUrl();
  const origin = request.nextUrl.origin;
  try {
    const parsed = new URL(location, base);
    if (parsed.origin === base.origin) {
      return `${origin}/api/fava${parsed.pathname}${parsed.search}${parsed.hash}`;
    }
  } catch {
    // Fall back to relative handling below.
  }
  if (location.startsWith("/")) return `${origin}/api/fava${location}`;
  return location;
}

function rewriteTextBody(body: string): string {
  return body
    .replaceAll('href="/', 'href="/api/fava/')
    .replaceAll("href='/", "href='/api/fava/")
    .replaceAll('src="/', 'src="/api/fava/')
    .replaceAll("src='/", "src='/api/fava/")
    .replaceAll('action="/', 'action="/api/fava/')
    .replaceAll("action='/", "action='/api/fava/")
    .replaceAll('url("/', 'url("/api/fava/')
    .replaceAll("url('/", "url('/api/fava/");
}

async function handler(request: NextRequest, context: { params: Promise<{ path?: string[] }> }) {
  try {
    await requireAuth();
  } catch (error) {
    if (error instanceof Response) return new NextResponse("Unauthorized", { status: error.status });
    throw error;
  }

  if (!favaEnabled()) {
    return new NextResponse("Fava integration is disabled. Set FAVA_ENABLED=true and run Fava on the configured FAVA_INTERNAL_URL.", {
      status: 404,
      headers: { "content-type": "text/plain; charset=utf-8" },
    });
  }

  const params = await context.params;
  const upstream = upstreamUrl(request, params.path ?? []);
  const method = request.method.toUpperCase();

  let upstreamResponse: Response;
  try {
    upstreamResponse = await fetch(upstream, {
      method,
      headers: proxyHeaders(request, upstream),
      body: method === "GET" || method === "HEAD" ? undefined : request.body,
      redirect: "manual",
      // Required when passing through the incoming request stream.
      duplex: method === "GET" || method === "HEAD" ? undefined : "half",
    } as RequestInit & { duplex?: "half" });
  } catch {
    return new NextResponse("Fava is not reachable. Check that beancount-fava is running on FAVA_INTERNAL_URL.", {
      status: 502,
      headers: { "content-type": "text/plain; charset=utf-8" },
    });
  }

  const headers = responseHeaders(upstreamResponse.headers);
  const location = upstreamResponse.headers.get("location");
  if (location) headers.set("location", rewriteLocation(location, request));

  const contentType = upstreamResponse.headers.get("content-type") ?? "";
  const shouldRewriteBody = contentType.includes("text/html") || contentType.includes("text/css") || contentType.includes("javascript");

  if (shouldRewriteBody) {
    const text = await upstreamResponse.text();
    headers.delete("content-length");
    return new NextResponse(rewriteTextBody(text), { status: upstreamResponse.status, headers });
  }

  return new NextResponse(upstreamResponse.body, { status: upstreamResponse.status, headers });
}

export const GET = handler;
export const POST = handler;
export const PUT = handler;
export const PATCH = handler;
export const DELETE = handler;
export const HEAD = handler;
export const OPTIONS = handler;
