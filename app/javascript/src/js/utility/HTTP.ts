export interface HTTPOptions {
  method?: string;
  params?: Record<string, string | number | undefined | null>;
  body?: FormData | URLSearchParams | string;
  headers?: Record<string, string>;
}

/**
 * Thin fetch wrapper: query-string serialization, CSRF on non-GET requests, and
 * same-origin credentials. Returns the raw Response so callers keep full control
 * over status/header/body handling (jQuery.ajax used to add CSRF via @rails/ujs;
 * fetch does not, so this is where the token is attached).
 */
export default class HTTP {
  static request (url: string, opts: HTTPOptions = {}): Promise<Response> {
    const method = (opts.method ?? "GET").toUpperCase();
    const headers: Record<string, string> = { ...(opts.headers ?? {}) };
    if (method !== "GET" && method !== "HEAD")
      headers["X-CSRF-Token"] = HTTP.csrfToken();

    return fetch(HTTP.withParams(url, opts.params), {
      method,
      headers,
      credentials: "same-origin", // Match jQuery XHR (withCredentials:false)
      body: opts.body,
    });
  }

  static get (url: string, params?: HTTPOptions["params"]): Promise<Response> {
    return HTTP.request(url, { method: "GET", params });
  }

  static async getJSON<T = any> (url: string, params?: HTTPOptions["params"]): Promise<T> {
    return HTTP.json(await HTTP.get(url, params));
  }

  static post (url: string, body?: HTTPOptions["body"], opts: HTTPOptions = {}): Promise<Response> {
    return HTTP.request(url, { ...opts, method: "POST", body });
  }

  static async postJSON<T = any> (url: string, body?: HTTPOptions["body"], opts: HTTPOptions = {}): Promise<T> {
    return HTTP.json(await HTTP.post(url, body, opts));
  }

  /**
   * Builds a user-facing message from a failed response. Handles every shape the backend
   * produces: `render_expected_error` (`message` / `reason`), responders validation
   * errors (`errors` as an array or an attribute hash), and non-JSON bodies such as
   * HTML error pages, which fall back to the status line.
   */
  static async errorMessage (response: Response, fallback?: string): Promise<string> {
    let body: any = null;
    try { body = await response.json(); } catch { /* not JSON */ }

    const message = HTTP.messageFromBody(body);
    if (message) return message;
    if (response.status === 404) return "Not Found";
    return fallback ?? `${response.status} ${response.statusText ?? ""}`.trim();
  }

  /**
   * The same, for a failed jQuery `$.ajax` request. A short plain-text body is used as it
   * is, since some endpoints answer with one. An HTML body never is: toasts render their
   * message as HTML, and a proxy error page (such as Cloudflare's 502) brings its own
   * stylesheet, which would restyle the whole page.
   */
  static xhrErrorMessage (xhr: JQuery.jqXHR, fallback?: string): string {
    let body: any = xhr.responseJSON;
    if (body === undefined) {
      try { body = JSON.parse(xhr.responseText ?? ""); } catch { /* not JSON */ }
    }
    const message = HTTP.messageFromBody(body);
    if (message) return message;

    const text = (xhr.responseText ?? "").trim();
    if (text && !text.includes("<") && text.length <= 500) return text;
    if (xhr.status === 404) return "Not Found";
    return fallback ?? (`${xhr.status || ""} ${xhr.statusText ?? ""}`.trim() || "Request failed");
  }

  // `render_expected_error` (`message` / `reason`) and responders validation errors
  // (`errors` as an array or an attribute hash).
  private static messageFromBody (body: any): string | null {
    if (!body || typeof body !== "object") return null;
    for (const key of ["message", "reason"])
      if (typeof body[key] === "string" && body[key]) return body[key];

    const errors = body.errors;
    const messages: string[] = Array.isArray(errors)
      ? errors
      : errors && typeof errors === "object" ? Object.values(errors).flat() : [];
    return messages.filter((msg) => typeof msg === "string" && msg).join("; ") || null;
  }

  // The JSON sugar only resolves on 2xx (an error body could still be valid JSON,
  // which callers must not mistake for success); use `request`/`get`/`post` for
  // non-ok handling.
  private static json<T> (response: Response): Promise<T> {
    if (!response.ok) throw new Error(`Request failed: ${response.status}`);
    return response.json();
  }

  private static csrfToken (): string {
    return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") ?? "";
  }

  private static withParams (url: string, params?: HTTPOptions["params"]): string {
    if (!params) return url;
    const search = new URLSearchParams();
    for (const [key, value] of Object.entries(params))
      if (value !== undefined && value !== null) search.append(key, String(value));
    const query = search.toString();
    return query ? `${url}?${query}` : url;
  }
}
