// The zone2.day mark served at /icon.png (and /favicon.ico) and advertised in MCP serverInfo.icons,
// so clients that read it show the right icon: prod orange, staging with a graphite corner.
import { PROD_ICON_PNG, STAGING_ICON_PNG } from "./icon_data.ts";

const decode = (b64: string) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));

export function iconPng(env: string): Uint8Array {
  return decode(env === "prod" ? PROD_ICON_PNG : STAGING_ICON_PNG);
}

/** MCP Implementation.icons (spec 2025-11-25). */
export function mcpIcons(publicBaseUrl: string) {
  return [{ src: `${publicBaseUrl}/icon.png`, mimeType: "image/png", sizes: ["256x256"] }];
}
