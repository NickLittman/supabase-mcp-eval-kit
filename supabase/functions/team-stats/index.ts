// Edge Function: team-stats
// Tests: deploy_edge_function, get_edge_function, list_edge_functions, get_logs(service: "edge-function")
//
// Calls the get_team_dashboard() RPC function and returns the result.
// Requires a valid JWT (verify_jwt: true) — tests auth flow end-to-end.
//
// Deploy via MCP:
//   deploy_edge_function(project_id, name="team-stats", entrypoint_path="index.ts", verify_jwt=true, files=[...])
//
// Invoke:
//   curl -i --request POST \
//     'https://<project-ref>.supabase.co/functions/v1/team-stats' \
//     --header 'Authorization: Bearer <user-jwt>' \
//     --header 'Content-Type: application/json' \
//     --data '{"team_id": "<uuid>"}'
//
// Or via supabase-js:
//   const { data, error } = await supabase.functions.invoke('team-stats', {
//     body: { team_id: '<uuid>' }
//   })

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers":
          "authorization, x-client-info, apikey, content-type",
      },
    });
  }

  try {
    const { team_id } = await req.json();

    if (!team_id) {
      return new Response(
        JSON.stringify({ error: "team_id is required" }),
        {
          status: 400,
          headers: { "Content-Type": "application/json" },
        },
      );
    }

    // Create Supabase client with the user's JWT for RLS
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const authHeader = req.headers.get("Authorization")!;

    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    // Call the RPC function — this goes through RLS
    const { data, error } = await supabase.rpc("get_team_dashboard", {
      p_team_id: team_id,
    });

    if (error) {
      return new Response(
        JSON.stringify({ error: error.message }),
        {
          status: 500,
          headers: { "Content-Type": "application/json" },
        },
      );
    }

    return new Response(
      JSON.stringify(data),
      {
        status: 200,
        headers: {
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*",
        },
      },
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: (err as Error).message }),
      {
        status: 500,
        headers: { "Content-Type": "application/json" },
      },
    );
  }
});
