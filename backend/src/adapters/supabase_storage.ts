// BlobStore on Supabase Storage REST API (service role key, private bucket).
// Portability: swap for an S3 adapter on a VPS; nothing else depends on Supabase here.
import type { BlobStore } from "../ports/blob.ts";

export class SupabaseStorage implements BlobStore {
  constructor(
    private readonly url: string,
    private readonly serviceKey: string,
    private readonly bucket: string,
  ) {}

  private headers(extra: Record<string, string> = {}) {
    return { authorization: `Bearer ${this.serviceKey}`, apikey: this.serviceKey, ...extra };
  }

  private objectUrl(key: string) {
    return `${this.url}/storage/v1/object/${this.bucket}/${
      key.split("/").map(encodeURIComponent).join("/")
    }`;
  }

  async put(key: string, body: Uint8Array, contentType: string): Promise<void> {
    const res = await fetch(this.objectUrl(key), {
      method: "POST",
      headers: this.headers({ "content-type": contentType, "x-upsert": "true" }),
      body: body as BodyInit,
    });
    if (!res.ok) throw new Error(`storage put ${key}: ${res.status} ${await res.text()}`);
  }

  async get(key: string): Promise<Uint8Array | null> {
    const res = await fetch(this.objectUrl(key), { headers: this.headers() });
    if (res.status === 404 || res.status === 400) {
      await res.body?.cancel();
      return null;
    }
    if (!res.ok) throw new Error(`storage get ${key}: ${res.status}`);
    return new Uint8Array(await res.arrayBuffer());
  }

  async signedUrl(key: string, expiresInSec: number): Promise<string> {
    const res = await fetch(
      `${this.url}/storage/v1/object/sign/${this.bucket}/${
        key.split("/").map(encodeURIComponent).join("/")
      }`,
      {
        method: "POST",
        headers: this.headers({ "content-type": "application/json" }),
        body: JSON.stringify({ expiresIn: expiresInSec }),
      },
    );
    if (!res.ok) throw new Error(`storage sign ${key}: ${res.status}`);
    const { signedURL } = await res.json() as { signedURL: string };
    return `${this.url}/storage/v1${signedURL}`;
  }
}
