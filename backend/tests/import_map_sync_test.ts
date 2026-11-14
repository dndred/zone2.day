// The Supabase function bundles backend code with its own import map
// (supabase/functions/api/deno.json). Keep it in sync with backend/deno.json.
import { assertEquals } from "@std/assert";

const root = new URL("../../", import.meta.url);
const readImports = async (path: string): Promise<Record<string, string>> =>
  JSON.parse(await Deno.readTextFile(new URL(path, root))).imports;

Deno.test("supabase function import map matches backend runtime imports", async () => {
  const backend = await readImports("backend/deno.json");
  const fn = await readImports("supabase/functions/api/deno.json");
  const runtimeOnly = Object.fromEntries(
    Object.entries(backend).filter(([name]) => !name.startsWith("@std/")),
  );
  assertEquals(fn, runtimeOnly);
});
