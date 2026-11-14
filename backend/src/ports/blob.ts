// Raw file storage (docs/02-architecture.md §5 rule 3): dumps, FIT, streams.
export interface BlobStore {
  put(key: string, body: Uint8Array, contentType: string): Promise<void>;
  get(key: string): Promise<Uint8Array | null>;
  /** Time-limited download URL for clients that can fetch files themselves. */
  signedUrl(key: string, expiresInSec: number): Promise<string>;
}

/** In-memory implementation for tests and local runs without Storage. */
export class MemoryBlobStore implements BlobStore {
  readonly objects = new Map<string, { body: Uint8Array; contentType: string }>();

  put(key: string, body: Uint8Array, contentType: string): Promise<void> {
    this.objects.set(key, { body, contentType });
    return Promise.resolve();
  }

  get(key: string): Promise<Uint8Array | null> {
    return Promise.resolve(this.objects.get(key)?.body ?? null);
  }

  signedUrl(key: string, expiresInSec: number): Promise<string> {
    return Promise.resolve(`memory://${key}?expires=${expiresInSec}`);
  }
}
