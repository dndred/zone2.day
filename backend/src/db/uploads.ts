// One-time upload links: the athlete uploads a file in the browser, the coach imports it via MCP.
import type { Sql } from "./client.ts";

export interface UploadRow {
  id: string;
  userId: string;
  kind: "fit";
  expiresAt: Date;
  storageKey: string | null;
  bytes: number | null;
  filename: string | null;
  uploadedAt: Date | null;
  activityId: string | null;
}

function toRow(r: Record<string, unknown>): UploadRow {
  return {
    id: r.id as string,
    userId: r.user_id as string,
    kind: r.kind as "fit",
    expiresAt: new Date(r.expires_at as string),
    storageKey: (r.storage_key as string) ?? null,
    bytes: (r.bytes as number) ?? null,
    filename: (r.filename as string) ?? null,
    uploadedAt: r.uploaded_at ? new Date(r.uploaded_at as string) : null,
    activityId: (r.activity_id as string) ?? null,
  };
}

export class UploadStore {
  constructor(readonly sql: Sql) {}

  async create(userId: string, tokenHash: string, kind: "fit", expiresAt: Date) {
    const [r] = await this.sql`insert into zone2.uploads (user_id, token_hash, kind, expires_at)
      values (${userId}, ${tokenHash}, ${kind}, ${expiresAt}) returning *`;
    return toRow(r);
  }

  /** By the URL token (the page has no bearer: the token is the credential). */
  async byToken(tokenHash: string) {
    const [r] = await this.sql`select * from zone2.uploads where token_hash = ${tokenHash}`;
    return r ? toRow(r) : null;
  }

  async get(userId: string, id: string) {
    const [r] = await this
      .sql`select * from zone2.uploads where user_id = ${userId} and id = ${id}`;
    return r ? toRow(r) : null;
  }

  /** First upload wins; a second one through the same link is refused. */
  async markUploaded(id: string, f: { key: string; bytes: number; filename: string | null }) {
    const [r] = await this.sql`update zone2.uploads set storage_key = ${f.key}, bytes = ${f.bytes},
        filename = ${f.filename}, uploaded_at = now()
      where id = ${id} and uploaded_at is null returning *`;
    return r ? toRow(r) : null;
  }

  async markImported(userId: string, id: string, activityId: string) {
    await this.sql`update zone2.uploads set activity_id = ${activityId}
      where user_id = ${userId} and id = ${id}`;
  }
}
