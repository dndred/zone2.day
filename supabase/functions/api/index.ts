// Thin Supabase wrapper. All logic lives in /backend (runtime-agnostic, see docs/02-architecture.md §5).
import { createSupabaseHandler } from "../../../backend/src/entry/supabase.ts";

Deno.serve(createSupabaseHandler());
