import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...corsHeaders, 'Content-Type': 'application/json' },
});

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Method not allowed.' }, 405);

  try {
    const url = Deno.env.get('SUPABASE_URL');
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!url || !anonKey || !serviceKey) return json({ error: 'Konfigurasi server belum lengkap.' }, 500);

    const authHeader = req.headers.get('Authorization') || '';
    const token = authHeader.replace(/^Bearer\s+/i, '');
    if (!token) return json({ error: 'Silakan masuk kembali sebagai Admin.' }, 401);

    const authClient = createClient(url, anonKey, { auth: { persistSession: false }, global: { headers: { Authorization: `Bearer ${token}` } } });
    const { data: authData, error: authError } = await authClient.auth.getUser(token);
    if (authError || !authData.user) return json({ error: 'Sesi login tidak valid. Silakan masuk kembali.' }, 401);

    const adminClient = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: caller, error: callerError } = await adminClient
      .from('profiles').select('id,role,account_status').eq('id', authData.user.id).single();
    if (callerError || caller?.role !== 'admin' || caller?.account_status !== 'active') {
      return json({ error: 'Akses ditolak. Hanya Admin Kanwil aktif yang dapat mengelola akun Admin.' }, 403);
    }

    const body = await req.json();
    if (body.action === 'list') {
      const { data: profiles, error: profileError } = await adminClient
        .from('profiles').select('id,full_name,role,account_status,created_at').eq('role', 'admin').order('created_at', { ascending: true });
      if (profileError) return json({ error: profileError.message }, 400);

      const authUsers = new Map<string, { email?: string }>();
      for (let page = 1; page <= 20; page++) {
        const { data, error } = await adminClient.auth.admin.listUsers({ page, perPage: 100 });
        if (error) return json({ error: error.message }, 400);
        for (const user of data.users) authUsers.set(user.id, { email: user.email });
        if (data.users.length < 100) break;
      }
      const users = (profiles || []).map((p) => ({ ...p, email: authUsers.get(p.id)?.email || '' }));
      return json({ users });
    }

    if (body.action === 'create') {
      const fullName = String(body.full_name || '').trim();
      const email = String(body.email || '').trim().toLowerCase();
      const password = String(body.password || '');
      if (fullName.length < 2 || fullName.length > 120) return json({ error: 'Nama lengkap harus 2–120 karakter.' }, 400);
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return json({ error: 'Format email tidak valid.' }, 400);
      if (password.length < 10) return json({ error: 'Password awal minimal 10 karakter.' }, 400);

      const { data: created, error: createError } = await adminClient.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: { full_name: fullName, provisioned_by: 'sipbh_admin' },
      });
      if (createError) return json({ error: createError.message }, 400);
      if (!created.user) return json({ error: 'Supabase tidak mengembalikan data pengguna.' }, 500);

      const { error: profileUpsertError } = await adminClient.from('profiles').upsert({
        id: created.user.id,
        full_name: fullName,
        role: 'admin',
        account_status: 'active',
        obh_id: null,
      }, { onConflict: 'id' });
      if (profileUpsertError) {
        await adminClient.auth.admin.deleteUser(created.user.id);
        return json({ error: `Profil Admin gagal dibuat: ${profileUpsertError.message}` }, 500);
      }
      return json({ success: true, user: { id: created.user.id, email, full_name: fullName } }, 201);
    }

    if (body.action === 'set_status') {
      const userId = String(body.user_id || '');
      const status = String(body.account_status || '');
      if (!userId || !['active', 'rejected'].includes(status)) return json({ error: 'Permintaan perubahan status tidak valid.' }, 400);
      if (userId === authData.user.id) return json({ error: 'Anda tidak dapat menonaktifkan akun yang sedang digunakan.' }, 400);
      const { data: target, error: targetError } = await adminClient.from('profiles')
        .select('id,role,account_status').eq('id', userId).single();
      if (targetError || target?.role !== 'admin') return json({ error: 'Akun Admin tidak ditemukan.' }, 404);
      if (status === 'rejected' && target.account_status === 'active') {
        const { count, error: countError } = await adminClient.from('profiles').select('id', { count: 'exact', head: true })
          .eq('role', 'admin').eq('account_status', 'active');
        if (countError) return json({ error: countError.message }, 400);
        if ((count || 0) <= 1) return json({ error: 'Tidak dapat menonaktifkan Admin aktif terakhir.' }, 400);
      }
      const { error: updateError } = await adminClient.from('profiles').update({ account_status: status }).eq('id', userId);
      if (updateError) return json({ error: updateError.message }, 400);
      return json({ success: true, account_status: status });
    }

    return json({ error: 'Aksi tidak dikenal.' }, 400);
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : 'Terjadi kesalahan pada server.' }, 500);
  }
});
