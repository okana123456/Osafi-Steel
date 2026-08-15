// Deploy as a Supabase Edge Function named "osafi-admin" with JWT verification disabled.
// New-business registration is authenticated by ADMIN_REGISTRATION_KEY.
// Existing-business team management requires a signed-in ops_manager user.
// Required custom secrets: ADMIN_REGISTRATION_KEY and OSAFI_SERVICE_ROLE_KEY.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

async function safeEqual(a: string, b: string) {
  const enc = new TextEncoder();
  const [aa, bb] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const [av, bv] = [new Uint8Array(aa), new Uint8Array(bb)];
  let diff = a.length ^ b.length;
  for (let i = 0; i < av.length; i++) diff |= av[i] ^ bv[i];
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("OSAFI_SERVICE_ROLE_KEY");
  if (!url) return reply({ error: "SUPABASE_URL is missing from the Edge Function environment" }, 500);
  if (!serviceKey) return reply({ error: "OSAFI_SERVICE_ROLE_KEY secret is missing" }, 500);

  const admin = createClient(url, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  try {
    let body;
    try {
      body = await req.json();
    } catch (_) {
      return reply({ error: "Invalid request body" }, 400);
    }

    if (body.action === "register_business") {
      const { email, password, full_name, business_name, admin_key } = body;
      if (![email, password, full_name, business_name, admin_key].every((x) => typeof x === "string" && x.trim())) {
        return reply({ error: "All registration fields are required" }, 400);
      }
      if (password.length < 8) return reply({ error: "Password must be at least 8 characters" }, 400);

      const expected = Deno.env.get("ADMIN_REGISTRATION_KEY") || "";
      if (!expected || !(await safeEqual(admin_key, expected))) {
        return reply({ error: "Invalid admin registration key" }, 403);
      }

      const { data: authData, error: authError } = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: { full_name },
      });
      if (authError) return reply({ error: authError.message }, 400);

      const userId = authData.user.id;
      const { data: business, error: businessError } = await admin
        .from("businesses")
        .insert({ name: business_name.trim() })
        .select()
        .single();
      if (businessError) {
        await admin.auth.admin.deleteUser(userId);
        return reply({ error: businessError.message }, 400);
      }

      const { error: profileError } = await admin
        .from("users")
        .insert({ id: userId, business_id: business.id, full_name: full_name.trim(), email: email.trim(), role: "ops_manager" });
      if (profileError) {
        await admin.from("businesses").delete().eq("id", business.id);
        await admin.auth.admin.deleteUser(userId);
        return reply({ error: profileError.message }, 400);
      }

      return reply({ ok: true });
    }

    if (body.action === "create_technician") {
      const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
      const { data: callerData, error: callerError } = await admin.auth.getUser(token);
      if (callerError || !callerData.user) return reply({ error: "Sign in required" }, 401);

      const { data: caller } = await admin
        .from("users")
        .select("business_id,role")
        .eq("id", callerData.user.id)
        .single();
      if (!caller || caller.role !== "ops_manager") {
        return reply({ error: "Only an Ops Manager can invite team members" }, 403);
      }

      const { email, full_name, phone, role, location, id_number, redirect_to } = body;
      if (![email, full_name, phone, location, id_number].every((x) => typeof x === "string" && x.trim())) {
        return reply({ error: "Name, email, phone, location and ID number are required" }, 400);
      }
      const allowedRoles = ["technician", "operations_manager", "store_manager", "accountant"];
      const nextRole = typeof role === "string" && allowedRoles.includes(role) ? role : "technician";

      const options: { data: Record<string, string>; redirectTo?: string } = {
        data: { full_name: full_name.trim() },
      };
      if (typeof redirect_to === "string" && /^https?:\/\//i.test(redirect_to)) {
        options.redirectTo = redirect_to;
      }

      const { data: invited, error } = await admin.auth.admin.inviteUserByEmail(email.trim(), options);
      if (error) return reply({ error: error.message }, 400);
      if (!invited.user?.id) return reply({ error: "Supabase did not return the invited user" }, 500);

      const { error: profileError } = await admin.from("users").insert({
        id: invited.user.id,
        business_id: caller.business_id,
        full_name: full_name.trim(),
        email: email.trim(),
        phone: phone.trim(),
        location: location.trim(),
        id_number: id_number.trim(),
        role: nextRole,
      });
      if (profileError) {
        await admin.auth.admin.deleteUser(invited.user.id);
        return reply({ error: profileError.message }, 400);
      }

      return reply({ ok: true, user_id: invited.user.id });
    }

    if (body.action === "remove_team_member") {
      const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
      const { data: callerData, error: callerError } = await admin.auth.getUser(token);
      if (callerError || !callerData.user) return reply({ error: "Sign in required" }, 401);

      const { data: caller } = await admin
        .from("users")
        .select("business_id,role")
        .eq("id", callerData.user.id)
        .single();
      if (!caller || caller.role !== "ops_manager") {
        return reply({ error: "Only an Ops Manager can remove team members" }, 403);
      }

      const userId = typeof body.user_id === "string" ? body.user_id : "";
      if (!userId) return reply({ error: "Team member id is required" }, 400);
      if (userId === callerData.user.id) return reply({ error: "You cannot delete your own manager account" }, 400);

      const { data: member, error: memberError } = await admin
        .from("users")
        .select("id,business_id,role,full_name")
        .eq("id", userId)
        .single();
      if (memberError || !member) return reply({ error: "Team member was not found" }, 404);
      if (member.business_id !== caller.business_id) return reply({ error: "Team member is not in your business" }, 403);
      if (member.role === "ops_manager") return reply({ error: "Manager accounts cannot be removed from Team" }, 403);

      // Do not delete the profile or Auth user: production checklists, messages,
      // approvals and audit records must continue to identify their author.
      // Banning the Auth account removes access while is_active hides the member
      // from current team and technician lists.
      const { error: banError } = await admin.auth.admin.updateUserById(userId, {
        ban_duration: "876000h",
      });
      if (banError) return reply({ error: banError.message }, 400);

      const { error: unassignError } = await admin
        .from("jobs")
        .update({ technician_id: null })
        .eq("technician_id", userId);
      if (unassignError) {
        await admin.auth.admin.updateUserById(userId, { ban_duration: "none" });
        return reply({ error: unassignError.message }, 400);
      }

      const { error: profileError } = await admin
        .from("users")
        .update({ is_active: false })
        .eq("id", userId);
      if (profileError) {
        await admin.auth.admin.updateUserById(userId, { ban_duration: "none" });
        return reply({ error: profileError.message }, 400);
      }

      return reply({ ok: true, deactivated: true });
    }

    if (body.action === "update_team_member") {
      const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
      const { data: callerData, error: callerError } = await admin.auth.getUser(token);
      if (callerError || !callerData.user) return reply({ error: "Sign in required" }, 401);

      const { data: caller } = await admin
        .from("users")
        .select("business_id,role")
        .eq("id", callerData.user.id)
        .single();
      if (!caller || caller.role !== "ops_manager") {
        return reply({ error: "Only an Ops Manager can edit team members" }, 403);
      }

      const userId = typeof body.user_id === "string" ? body.user_id : "";
      const fullName = typeof body.full_name === "string" ? body.full_name.trim() : "";
      const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
      const phone = typeof body.phone === "string" && body.phone.trim() ? body.phone.trim() : null;
      const location = typeof body.location === "string" ? body.location.trim() : "";
      const idNumber = typeof body.id_number === "string" ? body.id_number.trim() : "";
      const requestedRole = typeof body.role === "string" ? body.role : "technician";
      const allowedRoles = ["technician", "operations_manager", "store_manager", "accountant"];
      if (!userId || !fullName || !email || !phone || !location || !idNumber) {
        return reply({ error: "Team member, name, email, phone, location and ID number are required" }, 400);
      }

      const { data: member, error: memberError } = await admin
        .from("users")
        .select("id,business_id,role,full_name,email,phone,location,id_number")
        .eq("id", userId)
        .single();
      if (memberError || !member) return reply({ error: "Team member was not found" }, 404);
      if (member.business_id !== caller.business_id) {
        return reply({ error: "Team member is not in your business" }, 403);
      }
      if (member.role === "ops_manager" && userId !== callerData.user.id) {
        return reply({ error: "You cannot edit another manager account" }, 403);
      }
      const nextRole = member.role === "ops_manager"
        ? "ops_manager"
        : (allowedRoles.includes(requestedRole) ? requestedRole : member.role);

      if (member.role === "technician" && nextRole !== "technician") {
        const { error: unassignError } = await admin
          .from("jobs")
          .update({ technician_id: null })
          .eq("technician_id", userId);
        if (unassignError) return reply({ error: unassignError.message }, 400);
      }

      const { error: authUpdateError } = await admin.auth.admin.updateUserById(userId, {
        email,
        email_confirm: true,
        user_metadata: { full_name: fullName },
      });
      if (authUpdateError) return reply({ error: authUpdateError.message }, 400);

      const { error: profileError } = await admin
        .from("users")
        .update({ full_name: fullName, email, phone, location, id_number: idNumber, role: nextRole })
        .eq("id", userId);
      if (profileError) {
        await admin.auth.admin.updateUserById(userId, {
          email: member.email || undefined,
          email_confirm: true,
          user_metadata: { full_name: member.full_name },
        });
        return reply({ error: profileError.message }, 400);
      }

      return reply({ ok: true });
    }

    return reply({ error: "Unknown action" }, 400);
  } catch (error) {
    return reply({ error: error instanceof Error ? error.message : "Unexpected error" }, 500);
  }
});
