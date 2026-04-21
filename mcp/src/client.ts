/**
 * Minimal HTTP client for the wg0 brain. Wraps fetch() with the PAT
 * header and raises tool-visible errors on non-2xx responses so the
 * agent gets a readable explanation rather than "undefined" fallout.
 */

export interface Wg0ClientConfig {
  brainUrl: string;
  apiKey: string;
}

export class Wg0Error extends Error {
  constructor(
    message: string,
    public status: number,
    public body: unknown,
  ) {
    super(message);
    this.name = "Wg0Error";
  }
}

export class Wg0Client {
  constructor(private config: Wg0ClientConfig) {}

  setApiKey(apiKey: string) {
    this.config.apiKey = apiKey;
  }

  getApiKey(): string {
    return this.config.apiKey;
  }

  private headers(): Record<string, string> {
    return {
      Authorization: `Bearer ${this.config.apiKey}`,
      "Content-Type": "application/json",
      // Self-identifying User-Agent so the brain access log tells ops
      // where the request came from.
      "User-Agent": "wg0-mcp-server/0.2.0",
    };
  }

  private async request<T>(
    method: string,
    path: string,
    body?: unknown,
  ): Promise<T> {
    const url = `${this.config.brainUrl.replace(/\/$/, "")}${path}`;
    const init: RequestInit = {
      method,
      headers: this.headers(),
    };
    if (body !== undefined) {
      init.body = JSON.stringify(body);
    }
    const resp = await fetch(url, init);

    // Empty 204s come back fine.
    if (resp.status === 204) {
      return undefined as T;
    }

    const text = await resp.text();
    let parsed: unknown = undefined;
    if (text.length > 0) {
      try {
        parsed = JSON.parse(text);
      } catch {
        parsed = text;
      }
    }

    if (!resp.ok) {
      const detail =
        typeof parsed === "object" &&
        parsed !== null &&
        "detail" in parsed &&
        typeof (parsed as { detail: unknown }).detail === "string"
          ? (parsed as { detail: string }).detail
          : typeof parsed === "string"
            ? parsed
            : `HTTP ${resp.status}`;
      throw new Wg0Error(
        `wg0 brain ${method} ${path} failed: ${detail}`,
        resp.status,
        parsed,
      );
    }

    return parsed as T;
  }

  get<T>(path: string): Promise<T> {
    return this.request<T>("GET", path);
  }

  post<T>(path: string, body?: unknown): Promise<T> {
    return this.request<T>("POST", path, body ?? {});
  }

  patch<T>(path: string, body: unknown): Promise<T> {
    return this.request<T>("PATCH", path, body);
  }

  delete<T>(path: string): Promise<T> {
    return this.request<T>("DELETE", path);
  }
}
