// Edge Function used by the smoke test (optional).
// Deployed by tools/setup_supabase.sh remote (served automatically by tools/setup_supabase.sh local).
Deno.serve(async (req) => {
  const { name } = await req.json().catch(() => ({ name: "world" }));
  return new Response(JSON.stringify({ message: `Hello ${name}!` }), {
    headers: { "Content-Type": "application/json" },
  });
});
